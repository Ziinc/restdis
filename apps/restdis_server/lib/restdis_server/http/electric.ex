defmodule RestdisServer.HTTP.Electric do
  @moduledoc """
  Adapter for `GET` and `DELETE /v1/shape`.

  This is the only module that knows the Electric HTTP contract: every
  status code and every `electric-*` header appears here. It converts query
  parameters into a call to `RestdisElectric` and converts the domain result
  back into a `Plug.Conn` response.
  """

  import Plug.Conn

  alias RestdisElectric
  alias RestdisElectric.Offset

  @live_timeout_ms 20_000

  @doc """
  Handles `GET /v1/shape`: resolves a snapshot or a range of the shape log,
  and long-polls when `live=true` and there is nothing new yet.
  """
  @spec get_shape(Plug.Conn.t()) :: Plug.Conn.t()
  def get_shape(conn) do
    tenant_id = conn.assigns.tenant_id
    tenant_config = conn.assigns.tenant_config

    case RestdisElectric.subscribe(tenant_id, tenant_config, conn.params) do
      {:ok, %{messages: []} = result} ->
        if live?(conn.params) do
          await_live(conn, tenant_id, result)
        else
          send_shape(conn, result)
        end

      {:ok, result} ->
        send_shape(conn, result)

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

  defp live?(params), do: params["live"] in ["true", "1"]

  defp await_live(conn, tenant_id, %{handle: handle, offset: offset}) do
    case RestdisElectric.await(tenant_id, handle, offset, @live_timeout_ms) do
      {:ok, messages, new_offset} ->
        result = %{handle: handle, messages: messages, offset: new_offset, up_to_date: true}
        send_shape(conn, result)

      :timeout ->
        send_shape(conn, %{handle: handle, messages: [], offset: offset, up_to_date: true})
    end
  end

  defp send_shape(conn, %{
         handle: handle,
         messages: messages,
         offset: offset,
         up_to_date: up_to_date
       }) do
    body = Enum.map(messages, &encode_message/1) ++ control_messages(up_to_date)

    conn
    |> put_resp_header("electric-handle", handle)
    |> put_resp_header("electric-offset", Offset.encode(offset))
    |> put_resp_header("electric-up-to-date", to_string(up_to_date))
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(body))
  end

  defp control_messages(true), do: [%{headers: %{control: "up-to-date"}}]
  defp control_messages(false), do: []

  defp encode_message(%{control: control}) when not is_nil(control) do
    %{headers: %{control: control_wire(control)}}
  end

  defp encode_message(message) do
    %{
      key: message.key,
      value: message.value,
      headers: %{operation: Atom.to_string(message.operation)}
    }
  end

  defp control_wire(:up_to_date), do: "up-to-date"
  defp control_wire(:must_refetch), do: "must-refetch"

  defp send_must_refetch(conn, new_handle) do
    conn
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

  defp send_error(conn, {:unsupported_where, _}),
    do: bad_request(conn, "the 'where' parameter is not supported yet")

  defp send_error(conn, {:unsupported_replica, value}),
    do: bad_request(conn, "unsupported 'replica' value: #{value}")

  defp send_error(conn, {:unsupported_log_mode, value}),
    do: bad_request(conn, "unsupported 'log' value: #{value}")

  defp send_error(conn, {:invalid_offset, raw}),
    do: bad_request(conn, "invalid 'offset' parameter: #{inspect(raw)}")

  defp send_error(conn, {:missing_handle, _}),
    do: bad_request(conn, "missing 'handle' query parameter")

  defp send_error(conn, {:snapshot_failed, reason}),
    do: send_resp(conn, 502, Jason.encode!(%{error: "snapshot failed: #{inspect(reason)}"}))

  defp send_error(conn, reason), do: bad_request(conn, inspect(reason))

  defp bad_request(conn, message), do: send_resp(conn, 400, Jason.encode!(%{error: message}))
end
