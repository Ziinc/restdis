defmodule SupaCacherBuster.Worker.CoalesceSweeper do
  @moduledoc """
  Periodically sweeps the coalesce ETS table populated by
  `SupaCacherBuster.Worker.Supervisor` when per-tenant backpressure drops events.

  For every `(tenant_id, table)` bucket with `count > 0`, the sweeper resets the
  counter to 0 and issues a coarse `Restdis.Cache.flush_table/2`, then emits a
  `[:supa_cacher_buster, :backpressure, :flushed]` telemetry event with the
  coalesced count.
  """

  use GenServer

  alias SupaCacherBuster.Worker.Supervisor, as: WorkerSupervisor

  @default_interval_ms 1_000

  @doc """
  Starts the sweeper on its periodic timer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl GenServer
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)
    {:ok, _} = :timer.send_interval(interval, :sweep)
    {:ok, %{interval_ms: interval}}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    sweep()
    {:noreply, state}
  end

  @doc """
  Performs a single sweep pass. Exposed for testing.
  """
  @spec sweep() :: :ok
  def sweep do
    table = WorkerSupervisor.coalesce_table()

    case :ets.info(table) do
      :undefined ->
        :ok

      _ ->
        :ets.foldl(fn entry, _acc -> flush_entry(table, entry) end, :ok, table)

        :ok
    end
  end

  defp flush_entry(_table, {_key, count}) when count <= 0, do: :ok

  defp flush_entry(table, {{tenant_id, tbl} = key, count}) do
    # Subtract the observed count so events recorded mid-fold are not lost.
    :ets.update_counter(table, key, {2, -count}, {key, 0})
    Restdis.Cache.flush_table(tenant_id, tbl)

    :telemetry.execute(
      [:supa_cacher_buster, :backpressure, :flushed],
      %{coalesced_count: count},
      %{tenant_id: tenant_id, table: tbl}
    )

    :ok
  end
end
