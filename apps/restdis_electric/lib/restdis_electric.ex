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
  alias RestdisElectric.Handle
  alias RestdisElectric.Log
  alias RestdisElectric.Message
  alias RestdisElectric.Offset
  alias RestdisElectric.ShapeRegistry
  alias RestdisElectric.Snapshotter
  alias RestdisElectric.TableInfo

  @typedoc "Everything a single subscribe call needs, bundled to keep helper arities small."
  @type context :: %{tenant_id: String.t(), tenant_config: map(), definition: Definition.t()}

  @type subscribe_result :: %{
          handle: String.t(),
          messages: [Message.t()],
          offset: Offset.t(),
          up_to_date: boolean()
        }

  @type subscribe_error ::
          Definition.error()
          | {:invalid_offset, String.t() | nil}
          | {:missing_handle, nil}
          | {:snapshot_failed, term()}

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
    with {:ok, offset} <- decode_offset(raw_params["offset"]),
         {:ok, definition} <- Definition.new(tenant_id, raw_params) do
      ctx = %{tenant_id: tenant_id, tenant_config: tenant_config, definition: definition}
      do_subscribe(ctx, offset, raw_params["handle"])
    end
  end

  @doc """
  Blocks until the shape's log has a message after `since_offset`, or until
  `timeout_ms` elapses.
  """
  @spec await(String.t(), String.t(), Offset.t(), timeout()) ::
          {:ok, [Message.t()], Offset.t()} | :timeout
  def await(tenant_id, handle, since_offset, timeout_ms) do
    Log.await(tenant_id, handle, since_offset, timeout_ms)
  end

  @doc """
  Deletes a shape's log and stops tracking it for live updates.
  """
  @spec delete_shape(String.t(), String.t()) :: :ok
  def delete_shape(tenant_id, handle) do
    ShapeRegistry.unregister(tenant_id, handle)
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
        {:error, :must_refetch, expected_handle}

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

        {:ok, %{handle: handle, messages: messages, offset: last_offset, up_to_date: true}}

      {:error, reason} ->
        {:error, {:snapshot_failed, reason}}
    end
  end

  defp resume(ctx, offset, handle) do
    ShapeRegistry.register(ctx.tenant_id, ctx.definition.schema, ctx.definition.table, handle)

    case Log.read(ctx.tenant_id, handle, offset) do
      {:ok, messages, last_offset} ->
        {:ok,
         %{
           handle: handle,
           messages: messages,
           offset: Offset.max(offset, last_offset),
           up_to_date: true
         }}

      :error ->
        {:error, :must_refetch, Handle.new(ctx.definition)}
    end
  end

  # An empty log looks the same as a never-snapshotted one; re-snapshotting is wasted work, not a bug.
  defp ensure_snapshot(ctx, handle) do
    ShapeRegistry.register(ctx.tenant_id, ctx.definition.schema, ctx.definition.table, handle)

    case Log.read(ctx.tenant_id, handle, Offset.beginning()) do
      {:ok, [], :beginning} -> run_snapshot(ctx, handle)
      {:ok, _messages, _last_offset} -> :ok
      :error -> run_snapshot(ctx, handle)
    end
  end

  defp run_snapshot(ctx, handle) do
    {:ok, info} = TableInfo.fetch(ctx.definition.schema, ctx.definition.table)
    counter = :counters.new(1, [])

    Snapshotter.stream(ctx.tenant_config, ctx.definition, fn rows ->
      messages = Enum.map(rows, &snapshot_message(&1, info, counter))
      Log.append(ctx.tenant_id, handle, messages)
    end)
  end

  defp snapshot_message(row, info, counter) do
    op_offset = :counters.get(counter, 1)
    :counters.add(counter, 1, 1)
    key = Enum.map_join(info.primary_key, ",", &Map.get(row, &1))
    Message.change({0, op_offset}, :insert, key, row)
  end
end
