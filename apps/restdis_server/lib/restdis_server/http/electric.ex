defmodule RestdisServer.HTTP.Electric do
  @moduledoc """
  Adapter for `GET` and `DELETE /v1/shape`.

  This is the only module that knows the Electric HTTP contract: every
  status code and every `electric-*` header appears here. It converts query
  parameters into a call to `RestdisElectric` and converts the domain result
  back into a `Plug.Conn` response.

  ## Transports

  Long-polling and Server-Sent Events are two framings of the same domain
  call, `RestdisElectric.await/4`. The context reports that the log has passed
  an offset; deciding whether that becomes one JSON body or one more SSE event
  is this module's job, and no transport detail crosses back into the context.

  ## Caching

  A wrong cache header here is severe: mark a live response as permanent and a
  cache can serve it forever, so the client never advances again. The rules
  are therefore narrow.

  | Response | `cache-control` |
  | --- | --- |
  | Live, by long-poll or SSE | `no-store, no-cache, must-revalidate, max-age=0` |
  | Settled — a range the log has already passed | `public, max-age=604800, stale-while-revalidate=2629746, immutable` |
  | Up to date at the tip of the log | `public, max-age=5, stale-while-revalidate=5` |
  | An error, of any kind | `no-store` |

  Only a settled response is cacheable for long, and a settled response can
  never change: it stops at a boundary the log has already passed, so repeated
  reads produce the same bytes and the same `etag`.

  The `cursor` parameter carries no meaning for the log. It exists to change
  the URL, so that a live client reconnecting cannot be answered from a cached
  copy of its previous request. It is part of the `etag` for the same reason.
  """

  import Plug.Conn

  alias RestdisElectric
  alias RestdisElectric.Offset
  alias RestdisElectric.SnapshotDescriptor
  alias RestdisElectric.TableInfo

  @live_timeout_ms 20_000
  @keepalive_ms 21_000
  @sse_lifetime_ms 300_000

  # A settled range never changes, so cache it for a week; the tip may grow, so it expires in seconds.
  @settled_cache "public, max-age=604800, stale-while-revalidate=2629746, immutable"
  @tip_cache "public, max-age=5, stale-while-revalidate=5"
  @live_cache "no-store, no-cache, must-revalidate, max-age=0"
  @error_cache "no-store"

  @doc """
  Handles `GET /v1/shape`: resolves a snapshot or a range of the shape log,
  and long-polls when `live=true` and there is nothing new yet.
  """
  @spec get_shape(Plug.Conn.t()) :: Plug.Conn.t()
  def get_shape(conn) do
    tenant_id = conn.assigns.tenant_id
    tenant_config = conn.assigns.tenant_config

    case RestdisElectric.subscribe(tenant_id, tenant_config, conn.params) do
      {:ok, result} ->
        send_live_or_settled(conn, tenant_id, result)

      {:error, :must_refetch, new_handle} ->
        send_must_refetch(conn, new_handle)

      {:error, reason} ->
        send_error(conn, reason)
    end
  end

  @doc """
  Handles `DELETE /v1/shape`, when the tenant has `allow_shape_deletion` set.
  """
  @spec delete_shape(Plug.Conn.t()) :: Plug.Conn.t()
  def delete_shape(conn) do
    if conn.assigns.tenant_config[:allow_shape_deletion] do
      do_delete_shape(conn)
    else
      send_resp(conn, 404, Jason.encode!(%{error: "not found"}))
    end
  end

  defp do_delete_shape(conn) do
    case conn.params["handle"] do
      handle when is_binary(handle) and handle != "" ->
        RestdisElectric.delete_shape(conn.assigns.tenant_id, handle)
        send_resp(conn, 202, Jason.encode!(%{ok: true}))

      _ ->
        send_resp(conn, 400, Jason.encode!(%{error: "missing 'handle' query parameter"}))
    end
  end

  defp live?(params), do: truthy?(params["live"]) or sse?(params)
  defp sse?(params), do: truthy?(params["live_sse"])
  defp truthy?(value), do: value in ["true", "1"]

  defp send_live_or_settled(conn, tenant_id, result) do
    cond do
      sse?(conn.params) -> stream_sse(conn, tenant_id, result)
      result.messages == [] and live?(conn.params) -> await_live(conn, tenant_id, result)
      true -> send_shape(conn, result)
    end
  end

  defp await_live(conn, tenant_id, %{handle: handle, offset: offset} = result) do
    case RestdisElectric.await(tenant_id, handle, offset, @live_timeout_ms) do
      {:ok, messages, new_offset} ->
        send_shape(conn, live_result(result, messages, new_offset))

      :timeout ->
        send_shape(conn, live_result(result, [], offset))

      {:error, reason} ->
        send_error(conn, reason)
    end
  end

  defp live_result(result, messages, offset) do
    %{result | messages: messages, offset: offset, up_to_date: true, settled: false}
  end

  defp send_shape(conn, %{handle: handle, messages: messages, offset: offset} = result) do
    body = Enum.map(messages, &encode_message/1) ++ control_messages(result.up_to_date)

    conn
    |> shape_headers(handle, offset, result)
    |> cache_headers(cache_mode(conn.params, result), handle, offset)
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(body))
  end

  defp shape_headers(conn, handle, offset, result) do
    conn
    |> put_resp_header("electric-handle", handle)
    |> put_resp_header("electric-offset", Offset.encode(offset))
    |> put_resp_header("electric-up-to-date", to_string(result.up_to_date))
    |> put_resp_header("electric-schema", schema_header(result))
  end

  # The real client only needs the header present, one object per column with at least a `type`.
  defp schema_header(%{schema: schema, table: table, columns: columns}) do
    info =
      case TableInfo.fetch(schema, table) do
        {:ok, info} -> info
        :error -> %{columns: columns || [], types: %{}}
      end

    selected = columns || info.columns

    selected
    |> Map.new(fn column ->
      {column, %{type: Map.get(info.types, column, "text"), not_null: false}}
    end)
    |> Jason.encode!()
  end

  defp cache_mode(params, result) do
    cond do
      live?(params) -> :live
      result.settled -> :settled
      true -> :tip
    end
  end

  defp cache_headers(conn, mode, handle, offset) do
    conn
    |> put_resp_header("cache-control", cache_control(mode))
    |> put_resp_header("etag", etag(conn, handle, offset))
  end

  defp cache_control(:settled), do: @settled_cache
  defp cache_control(:tip), do: @tip_cache
  defp cache_control(:live), do: @live_cache

  # The body is the messages between the requested and reached offset, so those, the handle, and cursor identify it.
  defp etag(conn, handle, offset) do
    from = conn.params["offset"] || "-1"
    cursor = conn.params["cursor"] || ""
    ~s("#{handle}:#{from}:#{Offset.encode(offset)}:#{cursor}")
  end

  # -- Server-Sent Events -----------------------------------------------------

  defp stream_sse(conn, tenant_id, %{handle: handle, offset: offset} = result) do
    conn =
      conn
      |> shape_headers(handle, offset, result)
      |> cache_headers(:live, handle, offset)
      |> put_resp_header("x-accel-buffering", "no")
      |> put_resp_content_type("text/event-stream")
      |> send_chunked(200)

    events = Enum.map(result.messages, &encode_message/1) ++ control_messages(result.up_to_date)

    case send_events(conn, events) do
      {:ok, conn} -> sse_loop(conn, {tenant_id, handle}, offset, deadline())
      {:error, conn} -> conn
    end
  end

  defp sse_loop(conn, {tenant_id, handle} = shape, offset, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      conn
    else
      case RestdisElectric.await(tenant_id, handle, offset, keepalive_ms()) do
        {:ok, messages, new_offset} ->
          events = Enum.map(messages, &encode_message/1) ++ control_messages(true)
          continue(send_events(conn, events), shape, new_offset, deadline)

        :timeout ->
          # Keeps the connection, and any proxy in front, alive without telling the client anything new.
          continue(chunk(conn, ": keepalive\n\n"), shape, offset, deadline)

        # The 200 status and SSE headers are already sent, so a limit hit here can only end the stream.
        {:error, _reason} ->
          conn
      end
    end
  end

  defp continue({:ok, conn}, shape, offset, deadline),
    do: sse_loop(conn, shape, offset, deadline)

  # The client has gone. Nothing to clean up: the wait is already over.
  defp continue({:error, conn}, _shape, _offset, _deadline), do: conn

  defp send_events(conn, events) do
    Enum.reduce_while(events, {:ok, conn}, fn event, {:ok, conn} ->
      case chunk(conn, "data: " <> Jason.encode!(event) <> "\n\n") do
        {:ok, conn} -> {:cont, {:ok, conn}}
        {:error, _reason} -> {:halt, {:error, conn}}
      end
    end)
  end

  defp deadline do
    System.monotonic_time(:millisecond) +
      Application.get_env(:restdis_server, :sse_lifetime_ms, @sse_lifetime_ms)
  end

  defp keepalive_ms, do: Application.get_env(:restdis_server, :sse_keepalive_ms, @keepalive_ms)

  defp control_messages(true), do: [%{headers: %{control: "up-to-date"}}]
  defp control_messages(false), do: []

  defp encode_message(%{control: :snapshot_end, snapshot: descriptor}) do
    %{headers: %{control: "snapshot-end", snapshot: SnapshotDescriptor.to_string(descriptor)}}
  end

  defp encode_message(%{control: control}) when not is_nil(control) do
    %{headers: %{control: control_wire(control)}}
  end

  defp encode_message(message) do
    %{key: message.key, value: message.value, headers: message_headers(message)}
    |> put_old_value(message.old_value)
  end

  # The offset travels inside the message too: an SSE client reads one event at a time with no header to advance from.
  defp message_headers(%{offset: {lsn, op_position}} = message) do
    %{operation: Atom.to_string(message.operation), lsn: lsn, op_position: op_position}
  end

  defp message_headers(message), do: %{operation: Atom.to_string(message.operation)}

  # `old_value` appears only under `replica=full`, once the context decided the message carries the full old row.
  defp put_old_value(encoded, nil), do: encoded
  defp put_old_value(encoded, old_value), do: Map.put(encoded, :old_value, old_value)

  defp control_wire(:up_to_date), do: "up-to-date"
  defp control_wire(:must_refetch), do: "must-refetch"

  defp send_must_refetch(conn, new_handle) do
    conn
    |> put_resp_header("cache-control", @error_cache)
    |> put_resp_header("location", "/v1/shape?handle=#{new_handle}&offset=-1")
    |> send_resp(409, Jason.encode!(%{error: "shape handle no longer valid", handle: new_handle}))
  end

  defp send_error(conn, {:missing_table, _}),
    do: bad_request(conn, "missing 'table' query parameter")

  defp send_error(conn, {:unknown_table, table}),
    do: bad_request(conn, "unknown table '#{table}'")

  defp send_error(conn, {:missing_replica_identity, table}),
    do:
      bad_request(
        conn,
        "table '#{table}' does not have REPLICA IDENTITY FULL; run ALTER TABLE #{table} REPLICA IDENTITY FULL"
      )

  defp send_error(conn, {:missing_primary_key, columns}),
    do: bad_request(conn, "columns must include the primary key: #{Enum.join(columns, ", ")}")

  defp send_error(conn, {:unknown_columns, columns}),
    do: bad_request(conn, "unknown columns: #{Enum.join(columns, ", ")}")

  defp send_error(conn, {:unsupported_where, construct}),
    do: bad_request(conn, "unsupported construct in 'where': #{construct}")

  defp send_error(conn, {:invalid_where, message}),
    do: bad_request(conn, "invalid 'where' parameter: #{message}")

  defp send_error(conn, {:unsupported_replica, value}),
    do: bad_request(conn, "unsupported 'replica' value: #{value}")

  defp send_error(conn, {:unsupported_log_mode, value}),
    do: bad_request(conn, "unsupported 'log' value: #{value}")

  defp send_error(conn, {:missing_direct_pool, _}),
    do: bad_request(conn, "log=changes_only requires a direct Postgres pool for this tenant")

  defp send_error(conn, {:invalid_offset, raw}),
    do: bad_request(conn, "invalid 'offset' parameter: #{inspect(raw)}")

  defp send_error(conn, {:missing_handle, _}),
    do: bad_request(conn, "missing 'handle' query parameter")

  defp send_error(conn, {:snapshot_failed, {:limit_exceeded, _kind, _limit} = reason}),
    do: send_error(conn, reason)

  defp send_error(conn, {:limit_exceeded, :shapes, limit}),
    do: too_many_requests(conn, "tenant has reached its limit of #{limit} active shapes")

  defp send_error(conn, {:limit_exceeded, :log_bytes, limit}),
    do:
      too_many_requests(
        conn,
        "tenant has reached its limit of #{limit} bytes for a shape's log"
      )

  defp send_error(conn, {:limit_exceeded, :waiting_clients, limit}),
    do:
      too_many_requests(
        conn,
        "tenant has reached its limit of #{limit} clients waiting for a live update"
      )

  defp send_error(conn, {:snapshot_failed, reason}) do
    conn
    |> put_resp_header("cache-control", @error_cache)
    |> send_resp(502, Jason.encode!(%{error: "snapshot failed: #{inspect(reason)}"}))
  end

  defp too_many_requests(conn, message) do
    conn
    |> put_resp_header("cache-control", @error_cache)
    |> send_resp(429, Jason.encode!(%{error: message}))
  end

  defp bad_request(conn, message) do
    conn
    |> put_resp_header("cache-control", @error_cache)
    |> send_resp(400, Jason.encode!(%{error: message}))
  end
end
