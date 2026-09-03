defmodule RestdisElectric.SchemaWatcher do
  @moduledoc """
  Periodically compares the cached schema of every actively-watched table
  against its real, current schema, and invalidates every shape on a table
  whose schema drifted.

  This catches the schema changes that produce no WAL notification today —
  `ALTER TABLE ... ALTER COLUMN ... TYPE`, adding or dropping a column, and
  so on. `DROP TABLE` already gets its own signal from a DDL event trigger
  (see `RestdisBuster`); this module exists for everything that trigger
  does not cover.

  Invalidation reuses the exact mechanism a shape's own eviction or `DELETE
  /v1/shape` already uses: deleting the shape's log and dropping it from
  `RestdisElectric.ShapeRegistry`. The next request with that shape's handle
  finds no log to resume from, so `RestdisElectric.subscribe/3` returns
  `{:error, :must_refetch, new_handle}`, which the HTTP layer turns into a
  `409`. There is no second, parallel invalidation path.

  A table this process has never seen before is only cached, not
  invalidated: the first observation is the baseline, not a drift.
  """

  use GenServer

  alias RestdisElectric.Log
  alias RestdisElectric.ShapeRegistry
  alias RestdisElectric.TableInfo

  @default_interval_ms 60_000

  @doc """
  Starts the watcher on its periodic timer.

  Accepts `:interval_ms` (default #{@default_interval_ms}) and `:name`, so
  tests can run it on a short interval instead of the real 60 seconds.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl GenServer
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)
    {:ok, _} = :timer.send_interval(interval, :check)
    {:ok, %{interval_ms: interval, cache: %{}}}
  end

  @doc """
  Runs one drift-detection pass synchronously against the named process
  (default `#{inspect(__MODULE__)}`). Exposed so tests do not have to wait
  for the real interval.
  """
  @spec check(GenServer.server()) :: :ok
  def check(server \\ __MODULE__) do
    GenServer.call(server, :check)
  end

  @doc """
  Compares two schema snapshots as returned by `RestdisElectric.TableInfo.fetch/2`
  and decides whether they differ in any way a shape's log correctness
  depends on: columns, types, primary key, or replica identity.
  """
  @spec changed?(TableInfo.info(), TableInfo.info()) :: boolean()
  def changed?(old, new), do: old != new

  @impl GenServer
  def handle_info(:check, state) do
    {:noreply, do_check(state)}
  end

  @impl GenServer
  def handle_call(:check, _from, state) do
    new_state = do_check(state)
    {:reply, :ok, new_state}
  end

  defp do_check(state) do
    Enum.reduce(ShapeRegistry.tables(), state, &check_table/2)
  end

  defp check_table({tenant_id, schema, table}, state) do
    key = {tenant_id, schema, table}

    case TableInfo.fetch(schema, table) do
      {:ok, info} ->
        maybe_invalidate(Map.fetch(state.cache, key), info, key)
        put_in(state.cache[key], info)

      :error ->
        # The table itself is gone; the DDL drop-table trigger already handles this.
        state
    end
  end

  defp maybe_invalidate({:ok, cached}, info, table_key) do
    if changed?(cached, info), do: invalidate(table_key)
  end

  defp maybe_invalidate(:error, _info, _table_key), do: :ok

  defp invalidate({tenant_id, schema, table}) do
    for handle <- ShapeRegistry.handles_for(tenant_id, schema, table) do
      ShapeRegistry.unregister(tenant_id, handle)
      Log.delete(tenant_id, handle)
    end

    :ok
  end
end
