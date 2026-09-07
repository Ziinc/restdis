defmodule RestdisBuster.Worker.CoalesceSweeperTest do
  use ExUnit.Case, async: false

  alias RestdisBuster.Worker.CoalesceSweeper
  alias RestdisBuster.Worker.Supervisor, as: WorkerSupervisor

  @moduledoc """
  Proves `RestdisBuster.Worker.CoalesceSweeper` dispatches its backpressure
  fallback flush through the configured `Restdis.Wal.Handler` implementation
  rather than calling `Restdis.Cache` directly (QA gap found in PR #31,
  LIB_PRD Phase 4/5 dependency inversion).
  """

  defmodule StubHandler do
    @behaviour Restdis.Wal.Handler

    @impl Restdis.Wal.Handler
    def invalidate_by_row(_tenant_id, _table, _pk), do: :ok

    @impl Restdis.Wal.Handler
    def flush_table(tenant_id, table) do
      send(:coalesce_sweeper_test, {:flush_table, tenant_id, table})
      :ok
    end
  end

  setup do
    Process.register(self(), :coalesce_sweeper_test)
    Application.put_env(:restdis_buster, :wal_handler, StubHandler)

    on_exit(fn ->
      Application.delete_env(:restdis_buster, :wal_handler)

      try do
        Process.unregister(:coalesce_sweeper_test)
      rescue
        _ -> :ok
      end
    end)

    :ok
  end

  test "sweep/0 dispatches coalesced flushes through the configured handler's flush_table/2" do
    table = WorkerSupervisor.coalesce_table()
    key = {"tenant_stub", "products"}
    :ets.insert(table, {key, 3})

    on_exit(fn -> :ets.delete(table, key) end)

    CoalesceSweeper.sweep()

    assert_receive {:flush_table, "tenant_stub", "products"}, 200
  end

  test "sweep/0 skips entries with a zero or negative coalesced count" do
    table = WorkerSupervisor.coalesce_table()
    key = {"tenant_zero", "orders"}
    :ets.insert(table, {key, 0})

    on_exit(fn -> :ets.delete(table, key) end)

    CoalesceSweeper.sweep()

    refute_receive {:flush_table, "tenant_zero", "orders"}, 100
    assert :ets.lookup(table, key) == [{key, 0}]
  end

  test "init/1 schedules the periodic sweep and returns interval state" do
    # A long interval so the scheduled `:timer.send_interval` message doesn't
    # actually land in this (short-lived) test process's mailbox.
    assert {:ok, %{interval_ms: 3_600_000}} = CoalesceSweeper.init(interval_ms: 3_600_000)
  end

  test "handle_info(:sweep) runs a sweep pass" do
    table = WorkerSupervisor.coalesce_table()
    key = {"tenant_sweep", "widgets"}
    :ets.insert(table, {key, 2})
    on_exit(fn -> :ets.delete(table, key) end)

    assert {:noreply, %{interval_ms: 1_000}} =
             CoalesceSweeper.handle_info(:sweep, %{interval_ms: 1_000})

    assert_receive {:flush_table, "tenant_sweep", "widgets"}, 200
  end
end
