defmodule RestdisElectric do
  @moduledoc """
  Public API of the Electric-compatible shape context.

  This is the only module `restdis_server`'s HTTP adapter calls. It turns
  request parameters into a shape definition, drives the snapshot, reads and
  waits on the shape log, and deletes a shape. Every function here returns a
  domain value — `{:ok, ...}`, `{:error, reason}`, or `{:error, :must_refetch,
  new_handle}` — and never a `Plug.Conn` or an HTTP status code.
  """

  alias RestdisElectric.Definition
  alias RestdisElectric.Eval
  alias RestdisElectric.Handle
  alias RestdisElectric.Limits
  alias RestdisElectric.Log
  alias RestdisElectric.Message
  alias RestdisElectric.Offset
  alias RestdisElectric.ShapeRegistry
  alias RestdisElectric.Snapshotter
  alias RestdisElectric.Snapshotter.DirectPostgres
  alias RestdisElectric.SubqueryTracker
  alias RestdisElectric.TableInfo

  @typedoc "Everything a single subscribe call needs, bundled to keep helper arities small."
  @type context :: %{tenant_id: String.t(), tenant_config: map(), definition: Definition.t()}

  @typedoc """
  The result of one read of a shape log.

  `settled` marks a response whose content can never change: it stops at a
  boundary the log has already passed, so every later read of the same range
  produces the same bytes. The HTTP layer turns that into a long `max-age`.
  A response that reaches the tip of the log is never settled, because the
  next append extends it.
  """
  @type subscribe_result :: %{
          handle: String.t(),
          messages: [Message.t()],
          offset: Offset.t(),
          up_to_date: boolean(),
          settled: boolean(),
          schema: String.t(),
          table: String.t(),
          columns: [String.t()] | nil
        }

  @type subscribe_error ::
          Definition.error()
          | {:invalid_offset, String.t() | nil}
          | {:missing_handle, nil}
          | {:missing_direct_pool, nil}
          | {:snapshot_failed, term()}
          | Limits.limit_error()

  @doc """
  Child spec mounting the context's supervision tree in a host's own
  supervisor, e.g. `{RestdisElectric, []}`.

  `:restdis_electric` declares no `mod:` application callback, so depending
  on it starts no processes; a host must mount this explicitly.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {RestdisElectric.Supervisor, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc """
  Resolves `raw_params` (the request's query parameters, as string keys and
  values) into a shape log read: a snapshot when `offset` is `-1`, or the
  operations after `offset` when resuming with a `handle`.

  `tenant_config` must provide `:pgrst_base_url` (or `:replica_url`) and
  `:pgrst_api_key`, exactly as `restdis_server` already resolves it from an
  API key for `PGRST.QUERY`.
  """
  @spec subscribe(String.t(), map(), map()) ::
          {:ok, subscribe_result()}
          | {:error, subscribe_error()}
          | {:error, :must_refetch, new_handle :: String.t()}
  def subscribe(tenant_id, tenant_config, raw_params) do
    Limits.put_config(tenant_id, tenant_config)

    with {:ok, offset} <- decode_offset(raw_params["offset"]),
         {:ok, definition} <- Definition.new(tenant_id, raw_params),
         :ok <- check_direct_pool(definition, tenant_config) do
      ctx = %{tenant_id: tenant_id, tenant_config: tenant_config, definition: definition}

      case do_subscribe(ctx, offset, raw_params["handle"]) do
        {:ok, result} -> {:ok, with_table_identity(result, definition)}
        other -> other
      end
    end
  end

  defp with_table_identity(result, definition) do
    Map.merge(result, %{
      schema: definition.schema,
      table: definition.table,
      columns: definition.columns
    })
  end

  # `log=changes_only` without a direct pool would silently fall back to `full`, so it is a subscribe error.
  defp check_direct_pool(%Definition{log_mode: :changes_only}, tenant_config),
    do: ensure_direct_pool(tenant_config)

  # `RestdisElectric.SubqueryTracker` needs a direct pool to read the subquery's own table.
  defp check_direct_pool(%Definition{filter: filter}, tenant_config) do
    if Eval.subqueries(filter) == [] do
      :ok
    else
      ensure_direct_pool(tenant_config)
    end
  end

  defp ensure_direct_pool(tenant_config) do
    if tenant_config[:direct_pg_url] do
      :ok
    else
      {:error, {:missing_direct_pool, nil}}
    end
  end

  @doc """
  Blocks until the shape's log has a message after `since_offset`, or until
  `timeout_ms` elapses.
  """
  @spec await(String.t(), String.t(), Offset.t(), timeout()) ::
          {:ok, [Message.t()], Offset.t()} | :timeout | {:error, Limits.limit_error()}
  def await(tenant_id, handle, since_offset, timeout_ms) do
    with :ok <- Limits.enter_wait(tenant_id) do
      try do
        Log.await(tenant_id, handle, since_offset, timeout_ms)
      after
        Limits.exit_wait(tenant_id)
      end
    end
  end

  @doc """
  Deletes a shape's log and stops tracking it for live updates.
  """
  @spec delete_shape(String.t(), String.t()) :: :ok
  def delete_shape(tenant_id, handle) do
    ShapeRegistry.unregister(tenant_id, handle)
    SubqueryTracker.unregister_shape(tenant_id, handle)
    Log.delete(tenant_id, handle)
  end

  defp decode_offset(raw) do
    case Offset.decode(raw) do
      {:ok, offset} -> {:ok, offset}
      :error -> {:error, {:invalid_offset, raw}}
    end
  end

  defp do_subscribe(ctx, offset, given_handle) do
    expected_handle = Handle.new(ctx.definition)

    cond do
      Offset.equal?(offset, Offset.beginning()) ->
        handle =
          if given_handle && Handle.matches?(given_handle, ctx.definition),
            do: given_handle,
            else: expected_handle

        start_from_beginning(ctx, handle)

      is_nil(given_handle) ->
        {:error, {:missing_handle, nil}}

      not Handle.matches?(given_handle, ctx.definition) ->
        must_refetch(ctx, :handle_mismatch)

      true ->
        resume(ctx, offset, given_handle)
    end
  end

  defp start_from_beginning(ctx, handle) do
    case ensure_snapshot(ctx, handle) do
      :ok ->
        {messages, last_offset} =
          case Log.read(ctx.tenant_id, handle, Offset.beginning()) do
            {:ok, messages, last_offset} -> {messages, last_offset}
            # A table with no matching rows never gets a log entry written.
            :error -> {[], Offset.beginning()}
          end

        {:ok, from_beginning(handle, messages, last_offset)}

      {:error, {:limit_exceeded, _kind, _limit} = reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, {:snapshot_failed, reason}}
    end
  end

  # A read from `-1` stops at the snapshot's end once the log has passed it, so it is final and cacheable.
  defp from_beginning(handle, messages, last_offset) do
    {snapshot, rest} = Enum.split_with(messages, &Offset.snapshot?(&1.offset))

    if rest == [] do
      %{
        handle: handle,
        messages: snapshot,
        offset: last_offset,
        up_to_date: true,
        settled: false
      }
    else
      %{
        handle: handle,
        messages: snapshot,
        offset: Offset.snapshot_end(),
        up_to_date: false,
        settled: true
      }
    end
  end

  defp resume(ctx, offset, handle) do
    register(ctx, handle)

    if stale_offset?(ctx.tenant_id, handle, offset) do
      must_refetch(ctx, :retention)
    else
      case Log.read(ctx.tenant_id, handle, offset) do
        {:ok, messages, last_offset} ->
          {:ok,
           %{
             handle: handle,
             messages: messages,
             offset: Offset.max(offset, last_offset),
             up_to_date: true,
             settled: false
           }}

        :error ->
          must_refetch(ctx, :log_missing)
      end
    end
  end

  # A resume offset at or before the log's retention boundary asks for evicted operations.
  defp stale_offset?(tenant_id, handle, offset) do
    case Log.truncated_before(tenant_id, handle) do
      nil -> false
      truncated_before -> Offset.before?(offset, truncated_before)
    end
  end

  defp must_refetch(ctx, cause) do
    new_handle = Handle.new(ctx.definition)

    :telemetry.execute(
      [:restdis_electric, :shape, :must_refetch],
      %{count: 1},
      %{tenant_id: ctx.tenant_id, cause: cause}
    )

    {:error, :must_refetch, new_handle}
  end

  # An empty log looks the same as a never-snapshotted one; re-snapshotting is wasted work, not a bug.
  defp ensure_snapshot(ctx, handle) do
    case Log.read(ctx.tenant_id, handle, Offset.beginning()) do
      {:ok, [], :beginning} -> new_shape(ctx, handle)
      {:ok, _messages, _last_offset} -> register(ctx, handle)
      :error -> new_shape(ctx, handle)
    end
  end

  # A shape not yet in this log is new: it counts against the tenant's max_shapes.
  defp new_shape(ctx, handle) do
    case Limits.check_shapes(ctx.tenant_id) do
      :ok ->
        finish_new_shape(ctx, handle)

      {:error, {:limit_exceeded, :shapes, _limit}} = error ->
        case evict_lru(ctx.tenant_id) do
          :ok -> finish_new_shape(ctx, handle)
          :none -> error
        end
    end
  end

  defp finish_new_shape(ctx, handle) do
    register(ctx, handle)
    run_snapshot(ctx, handle)
  end

  # Electric's LRU shape cache at capacity; reuses delete_shape/2 so the victim must-refetches.
  defp evict_lru(tenant_id) do
    tenant_id
    |> ShapeRegistry.least_recently_used()
    |> Enum.find(&(not Log.waiting?(tenant_id, &1)))
    |> case do
      nil ->
        :none

      victim ->
        :telemetry.execute(
          [:restdis_electric, :shape, :must_refetch],
          %{count: 1},
          %{tenant_id: tenant_id, cause: :shape_limit_exceeded}
        )

        delete_shape(tenant_id, victim)
        :ok
    end
  end

  defp register(ctx, handle) do
    ShapeRegistry.register(ctx.tenant_id, ctx.definition, handle)
    SubqueryTracker.register_shape(ctx.tenant_id, ctx.tenant_config, ctx.definition, handle)
  end

  defp run_snapshot(ctx, handle) do
    method = snapshot_method(ctx.definition)
    result = run_snapshot(method, ctx, handle)

    :telemetry.execute(
      [:restdis_electric, :snapshot, :method],
      %{count: 1},
      %{tenant_id: ctx.tenant_id, table: ctx.definition.table, method: method}
    )

    result
  end

  # `changes_only` sends the descriptor, not the rows: the client already has every row through its own replica.
  defp run_snapshot(:direct_postgres, ctx, handle) do
    case DirectPostgres.snapshot_descriptor(ctx.tenant_config, ctx.definition) do
      {:ok, descriptor} ->
        Log.append(ctx.tenant_id, handle, [Message.snapshot_end({0, 0}, descriptor)])

      {:error, reason} ->
        {:error, reason}
    end
  end

  # `page_fun`'s return is discarded by every `Snapshotter`, so a limit hit reports via `page_ctx.error_box`.
  defp run_snapshot(:postgrest, ctx, handle) do
    {:ok, info} = TableInfo.fetch(ctx.definition.schema, ctx.definition.table)
    {:ok, error_box} = Agent.start_link(fn -> nil end)

    page_ctx = %{
      ctx: ctx,
      handle: handle,
      info: info,
      counter: :counters.new(1, []),
      error_box: error_box
    }

    stream_result =
      Snapshotter.stream(ctx.tenant_config, ctx.definition, &append_page(&1, page_ctx))

    reason = Agent.get(error_box, & &1)
    Agent.stop(error_box)

    case reason do
      nil -> stream_result
      limit_error -> {:error, limit_error}
    end
  end

  defp append_page(rows, page_ctx) do
    %{ctx: ctx, handle: handle, info: info, counter: counter, error_box: error_box} = page_ctx
    resolver = SubqueryTracker.resolver(ctx.tenant_id, handle)

    messages =
      rows
      |> Enum.filter(&Eval.matches?(ctx.definition.filter, &1, resolver))
      |> Enum.map(&snapshot_message(&1, ctx.definition, info, counter))

    case Log.append(ctx.tenant_id, handle, messages) do
      :ok -> :ok
      {:error, reason} -> Agent.update(error_box, fn _ -> reason end)
    end
  end

  # `changes_only` always reads through the tenant's direct Postgres pool; every other shape reads through PostgREST.
  defp snapshot_method(%Definition{log_mode: :changes_only}), do: :direct_postgres
  defp snapshot_method(%Definition{}), do: :postgrest

  # Filtering here, not in the origin query, makes snapshot and log agree by construction: both use `Eval`.
  defp snapshot_message(row, definition, info, counter) do
    op_offset = :counters.get(counter, 1)
    :counters.add(counter, 1, 1)
    key = Enum.map_join(info.primary_key, ",", &Map.get(row, &1))
    Message.change({0, op_offset}, :insert, key, project(definition, row))
  end

  defp project(%Definition{columns: nil}, row), do: row
  defp project(%Definition{columns: columns}, row), do: Map.take(row, columns)
end
