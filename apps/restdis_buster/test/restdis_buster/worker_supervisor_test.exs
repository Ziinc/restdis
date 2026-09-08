defmodule RestdisBuster.Worker.SupervisorTest do
  use ExUnit.Case, async: false

  alias RestdisBuster.TestUtils
  alias RestdisBuster.WAL.Event
  alias RestdisBuster.Worker.Supervisor, as: WorkerSupervisor

  setup do
    TestUtils.checkout_shared_repo!()
    Process.register(self(), :worker_supervisor_test)

    on_exit(fn ->
      try do
        Process.unregister(:worker_supervisor_test)
      rescue
        _ -> :ok
      end
    end)

    :ok
  end

  defp seed_config(schema, table, config), do: TestUtils.seed_table_config(schema, table, config)
  defp clear_config, do: TestUtils.clear_table_config()

  defp runner(event) do
    send(:worker_supervisor_test, {:ran, event})
    :ok
  end

  test "semaphores_table/0 and coalesce_table/0 return their configured ETS table names" do
    assert WorkerSupervisor.semaphores_table() == :restdis_buster_tenant_semaphores
    assert WorkerSupervisor.coalesce_table() == :restdis_buster_coalesce
  end

  test "init/1 tolerates ETS tables that already exist (the app already started this supervisor)" do
    assert {:ok, %{strategy: :one_for_one, max_children: 5_000}} = WorkerSupervisor.init([])
  end

  test "a DDL message event bypasses backpressure" do
    event = %Event{op: :message, schema: "public", table: "whatever"}
    assert :ok = WorkerSupervisor.start_worker(event, &runner/1)
    assert_receive {:ran, ^event}, 200
  end

  test "an event on public.tenant_table_config bypasses backpressure" do
    event = %Event{op: :update, schema: "public", table: "tenant_table_config"}
    assert :ok = WorkerSupervisor.start_worker(event, &runner/1)
    assert_receive {:ran, ^event}, 200
  end

  test "an event for an unconfigured table is a no-op" do
    event = %Event{op: :insert, schema: "public", table: "no_such_table_at_all"}
    assert :ok = WorkerSupervisor.start_worker(event, &runner/1)
    refute_receive {:ran, _}, 100
  end

  test "an event for a configured tenant runs the worker under backpressure" do
    config = %{
      tenant_id: "sup_test_tenant",
      schema: "public",
      table_name: "sup_test_table",
      pk_column: "id",
      mode: "ttl"
    }

    seed_config("public", "sup_test_table", config)
    on_exit(&clear_config/0)

    event = %Event{op: :insert, schema: "public", table: "sup_test_table"}
    assert :ok = WorkerSupervisor.start_worker(event, &runner/1)
    assert_receive {:ran, ^event}, 200
  end
end
