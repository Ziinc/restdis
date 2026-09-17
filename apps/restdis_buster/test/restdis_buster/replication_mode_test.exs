defmodule RestdisBuster.ReplicationModeTest do
  use ExUnit.Case, async: false

  alias Restdis.Cache.Key
  alias Restdis.Cache.TenantSupervisor
  alias RestdisBuster.Singleton
  alias RestdisBuster.TestUtils
  alias RestdisBuster.Worker

  defmodule StubDispatcher do
    def dispatch(config, op, row) do
      send(:replication_mode_test, {:dispatched, config.table_name, op, row})
      :ok
    end
  end

  defmodule StubReconciler do
    def reconcile_all do
      send(:replication_mode_test, :reconcile_all)
      :ok
    end
  end

  setup do
    Process.register(self(), :replication_mode_test)
    Application.put_env(:restdis_buster, :replication_dispatcher, StubDispatcher)

    on_exit(fn ->
      Application.put_env(:restdis_buster, :replication_dispatcher, nil)
      TestUtils.clear_table_config()
    end)

    TenantSupervisor.ensure_started(Restdis.Cache, "repl_tenant")
    on_exit(fn -> Restdis.Cache.flush_tenant("repl_tenant") end)

    TestUtils.seed_table_config(
      "public",
      "products",
      %{
        tenant_id: "repl_tenant",
        schema: "public",
        table_name: "products",
        pk_column: "id",
        mode: "replication"
      }
    )

    :ok
  end

  test "a DML event on a replication-mode table dispatches a refresh, not an invalidation" do
    key = Key.build(:table, "products", %{})
    Restdis.Cache.put("repl_tenant", key, %{"id" => 42}, primary_keys: [42])

    event =
      TestUtils.update_event("products", "public", %{"id" => "42"}, %{
        "id" => "42",
        "name" => "Updated"
      })

    Worker.run(event)

    assert_receive {:dispatched, "products", :update, %{"id" => "42"}}, 500
    assert {:ok, _} = Restdis.Cache.peek("repl_tenant", key)
  end

  test "a DELETE on a replication-mode table dispatches the delete" do
    event = TestUtils.delete_event("products", "public", %{"id" => "7"})

    Worker.run(event)

    assert_receive {:dispatched, "products", :delete, %{"id" => "7"}}, 500
  end

  test "acquiring the WAL tailer singleton triggers post-failover reconciliation" do
    Application.put_env(:restdis_buster, :failover_reconciler, StubReconciler)
    on_exit(fn -> Application.put_env(:restdis_buster, :failover_reconciler, nil) end)

    Singleton.notify_ownership_acquired()

    assert_receive :reconcile_all, 500
  end
end
