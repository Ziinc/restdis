defmodule SupaCacherBuster.Worker.BackpressureTest do
  use ExUnit.Case, async: false

  alias SupaCacherBuster.TestUtils
  alias SupaCacherBuster.Worker.CoalesceSweeper
  alias SupaCacherBuster.Worker.Supervisor, as: WorkerSupervisor
  alias SupaCacherCache.Key
  alias SupaCacherCache.TenantSupervisor

  @config_table :supa_cacher_buster_table_config
  @semaphores_table :supa_cacher_buster_tenant_semaphores
  @coalesce_table :supa_cacher_buster_coalesce
  @tenant "bp_tenant"
  @table "bp_widgets"

  defp seed_config do
    config = %{
      tenant_id: @tenant,
      schema: "public",
      table_name: @table,
      pk_column: "id",
      mode: "ttl"
    }

    :ets.insert(@config_table, {{"public", @table}, config})
  end

  defp clear_state do
    :ets.match_delete(@config_table, {{"public", @table}, :_})
    :ets.delete(@semaphores_table, @tenant)
    :ets.match_delete(@coalesce_table, {{@tenant, :_}, :_})
  end

  setup do
    Application.put_env(:supa_cacher_buster, :worker_per_tenant_cap, 2)
    TenantSupervisor.ensure_started(@tenant)
    seed_config()

    # The application-level CoalesceSweeper runs on a 1s timer and would race
    # with assertions that observe the coalesce ETS table. Stop it for the
    # duration of the test; the umbrella's top supervisor will restart it.
    sweeper_pid = Process.whereis(CoalesceSweeper)

    if sweeper_pid do
      ref = Process.monitor(sweeper_pid)
      Supervisor.terminate_child(SupaCacherBuster.Supervisor, CoalesceSweeper)

      receive do
        {:DOWN, ^ref, :process, _, _} -> :ok
      after
        500 -> :ok
      end
    end

    on_exit(fn ->
      Application.delete_env(:supa_cacher_buster, :worker_per_tenant_cap)
      SupaCacherCache.flush_tenant(@tenant)
      clear_state()
      _ = Supervisor.restart_child(SupaCacherBuster.Supervisor, CoalesceSweeper)
    end)

    :ok
  end

  test "exceeding per-tenant cap coalesces events and emits telemetry" do
    test_pid = self()
    ref = make_ref()

    :telemetry.attach(
      "bp-triggered-#{inspect(ref)}",
      [:supa_cacher_buster, :backpressure, :triggered],
      fn _e, measurements, metadata, _ ->
        send(test_pid, {:triggered, ref, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("bp-triggered-#{inspect(ref)}") end)

    # Runner that blocks until released, occupying a slot.
    blocking_runner = fn _event ->
      send(test_pid, {:running, ref, self()})

      receive do
        {:release, ^ref} -> :ok
      after
        5_000 -> :timeout
      end
    end

    event1 = TestUtils.insert_event(@table, "public", %{"id" => 1})
    event2 = TestUtils.insert_event(@table, "public", %{"id" => 2})
    event3 = TestUtils.insert_event(@table, "public", %{"id" => 3})

    :ok = WorkerSupervisor.start_worker(event1, blocking_runner)
    :ok = WorkerSupervisor.start_worker(event2, blocking_runner)

    # Wait for both workers to actually be running (semaphore acquired).
    assert_receive {:running, ^ref, pid1}, 1_000
    assert_receive {:running, ^ref, pid2}, 1_000

    # The third event should be coalesced — no Task should run.
    :ok = WorkerSupervisor.start_worker(event3, blocking_runner)

    assert_receive {:triggered, ^ref, %{count: 1}, %{tenant_id: @tenant, table: @table}},
                   1_000

    refute_receive {:running, ^ref, _}, 100

    # Coalesce counter should be 1.
    assert [{{@tenant, @table}, 1}] =
             :ets.lookup(@coalesce_table, {@tenant, @table})

    # Release the blocked workers so they exit cleanly.
    send(pid1, {:release, ref})
    send(pid2, {:release, ref})
  end

  test "CoalesceSweeper.sweep flushes coalesced buckets and emits telemetry" do
    test_pid = self()
    ref = make_ref()

    :telemetry.attach(
      "bp-flushed-#{inspect(ref)}",
      [:supa_cacher_buster, :backpressure, :flushed],
      fn _e, measurements, metadata, _ ->
        send(test_pid, {:flushed, ref, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("bp-flushed-#{inspect(ref)}") end)

    # Seed a cache entry that we expect the coarse flush_table to invalidate.
    key = Key.build(:table, @table, %{})
    SupaCacherCache.put(@tenant, key, %{"id" => 1}, primary_keys: [1])
    assert {:ok, _} = SupaCacherCache.peek(@tenant, key)

    # Pretend backpressure dropped 3 events.
    :ets.insert(@coalesce_table, {{@tenant, @table}, 3})

    :ok = CoalesceSweeper.sweep()

    assert :miss = SupaCacherCache.peek(@tenant, key)

    assert_receive {:flushed, ^ref, %{coalesced_count: 3}, %{tenant_id: @tenant, table: @table}},
                   500

    # Counter should be reset to 0.
    assert [{{@tenant, @table}, 0}] =
             :ets.lookup(@coalesce_table, {@tenant, @table})
  end

  test "infra table events bypass backpressure (always spawn)" do
    Application.put_env(:supa_cacher_buster, :worker_per_tenant_cap, 0)
    on_exit(fn -> Application.put_env(:supa_cacher_buster, :worker_per_tenant_cap, 2) end)

    test_pid = self()
    ref = make_ref()

    runner = fn _event -> send(test_pid, {:ran, ref}) end

    event = %SupaCacherBuster.WAL.Event{
      op: :update,
      schema: "public",
      table: "tenants",
      new_row: %{"tenant_id" => "x"}
    }

    :ok = WorkerSupervisor.start_worker(event, runner)
    assert_receive {:ran, ^ref}, 500
  end
end
