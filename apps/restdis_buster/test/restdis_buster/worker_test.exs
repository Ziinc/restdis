defmodule RestdisBuster.WorkerTest do
  use ExUnit.Case, async: false

  alias Restdis.Cache.Key
  alias Restdis.Cache.TenantSupervisor
  alias RestdisBuster.TestUtils
  alias RestdisBuster.Worker

  # Stub TenantTableConfig to avoid DB calls
  defmodule StubTableConfig do
    def lookup("public", "products"),
      do:
        {:ok,
         %{
           tenant_id: "tenant1",
           schema: "public",
           table_name: "products",
           pk_column: "id",
           mode: "ttl"
         }}

    def lookup("public", "orders"),
      do:
        {:ok,
         %{
           tenant_id: "tenant2",
           schema: "public",
           table_name: "orders",
           pk_column: "order_id",
           mode: "ttl"
         }}

    def lookup(_, _), do: :not_found
    def invalidate(_, _), do: :ok
  end

  defmodule StubInvalidator do
    def invalidate(tenant_id) do
      send(:worker_test, {:invalidate_called, tenant_id})
    end
  end

  setup do
    Process.register(self(), :worker_test)

    on_exit(fn ->
      try do
        Process.unregister(:worker_test)
      rescue
        _ -> :ok
      end
    end)

    :ok
  end

  setup do
    # Start tenants used in tests
    TenantSupervisor.ensure_started("tenant1")
    TenantSupervisor.ensure_started("tenant2")

    on_exit(fn ->
      Restdis.Cache.flush_tenant("tenant1")
      Restdis.Cache.flush_tenant("tenant2")
    end)

    :ok
  end

  # Helper to seed the TenantTableConfig ETS table directly
  defp seed_config(schema, table, config) do
    TestUtils.seed_table_config(schema, table, config)
  end

  defp clear_config do
    TestUtils.clear_table_config()
  end

  test "DML event for a configured table invalidates the cached entry" do
    config = %{
      tenant_id: "tenant1",
      schema: "public",
      table_name: "products",
      pk_column: "id",
      mode: "ttl"
    }

    seed_config("public", "products", config)
    on_exit(&clear_config/0)

    key = Key.build(:table, "products", %{})
    Restdis.Cache.put("tenant1", key, %{"id" => "42"}, primary_keys: [42])

    assert {:ok, _} = Restdis.Cache.peek("tenant1", key)

    event =
      TestUtils.update_event("products", "public", %{"id" => "42"}, %{
        "id" => "42",
        "name" => "Updated"
      })

    Worker.run(event)

    assert :miss = Restdis.Cache.peek("tenant1", key)
  end

  test "DML event with string PK coerced to integer matches integer PK in index" do
    config = %{
      tenant_id: "tenant1",
      schema: "public",
      table_name: "products",
      pk_column: "id",
      mode: "ttl"
    }

    seed_config("public", "products", config)
    on_exit(&clear_config/0)

    key = Key.build(:table, "products", %{})
    Restdis.Cache.put("tenant1", key, [%{"id" => 7}], primary_keys: [7])

    assert {:ok, _} = Restdis.Cache.peek("tenant1", key)

    event = TestUtils.delete_event("products", "public", %{"id" => "7"})
    Worker.run(event)

    assert :miss = Restdis.Cache.peek("tenant1", key)
  end

  test "DML event for unconfigured table is a no-op" do
    key = Key.build(:table, "unknown_table", %{})
    TenantSupervisor.ensure_started("some-tenant")
    Restdis.Cache.put("some-tenant", key, %{"id" => 1}, primary_keys: [1])

    event = TestUtils.insert_event("unknown_table")
    assert :ok = Worker.run(event)

    assert {:ok, _} = Restdis.Cache.peek("some-tenant", key)
    Restdis.Cache.flush_tenant("some-tenant")
  end

  test "Truncate event flushes table cache" do
    config = %{
      tenant_id: "tenant1",
      schema: "public",
      table_name: "products",
      pk_column: "id",
      mode: "ttl"
    }

    seed_config("public", "products", config)
    on_exit(&clear_config/0)

    key1 = Key.build(:table, "products", %{"select" => "id"})
    key2 = Key.build(:table, "products", %{"select" => "name"})
    Restdis.Cache.put("tenant1", key1, %{"id" => 1}, primary_keys: [1])
    Restdis.Cache.put("tenant1", key2, %{"id" => 2}, primary_keys: [2])

    event = TestUtils.truncate_event("products")
    Worker.run(event)

    assert :miss = Restdis.Cache.peek("tenant1", key1)
    assert :miss = Restdis.Cache.peek("tenant1", key2)
  end

  test "WAL event on public.tenants calls tenant_config_invalidator" do
    Application.put_env(:restdis_buster, :tenant_config_invalidator, StubInvalidator)
    on_exit(fn -> Application.put_env(:restdis_buster, :tenant_config_invalidator, nil) end)

    event =
      TestUtils.update_event("tenants", "public", %{"tenant_id" => "t1"}, %{"tenant_id" => "t1"})

    Worker.run(event)

    assert_receive {:invalidate_called, "t1"}, 200
  end

  test "WAL event on public.tenant_table_config flushes that table's cache" do
    config = %{
      tenant_id: "tenant1",
      schema: "public",
      table_name: "products",
      pk_column: "id",
      mode: "ttl"
    }

    seed_config("public", "products", config)
    on_exit(&clear_config/0)

    key = Key.build(:table, "products", %{})
    Restdis.Cache.put("tenant1", key, %{"id" => 3}, primary_keys: [3])

    event = %RestdisBuster.WAL.Event{
      op: :update,
      schema: "public",
      table: "tenant_table_config",
      new_row: %{"tenant_id" => "tenant1", "schema" => "public", "table_name" => "products"}
    }

    Worker.run(event)
    assert :miss = Restdis.Cache.peek("tenant1", key)
  end

  test "DML event for a replication-mode table casts row values to their Postgres types before reaching a shape" do
    config = %{
      tenant_id: "tenant1",
      schema: "public",
      table_name: "widgets",
      pk_column: "id",
      mode: "replication"
    }

    seed_config("public", "widgets", config)
    on_exit(&clear_config/0)

    Application.put_env(:restdis_electric, :tables, %{
      "public.widgets" => %{
        columns: ["id", "active", "name"],
        primary_key: ["id"],
        types: %{"id" => "integer", "active" => "boolean", "name" => "text"}
      }
    })

    on_exit(fn -> Application.delete_env(:restdis_electric, :tables) end)

    case RestdisElectric.Supervisor.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok = RestdisElectric.ShapeRegistry.register("tenant1", "public", "widgets", "h1")

    event = %{
      TestUtils.insert_event("widgets", "public", %{"id" => "3", "active" => "t", "name" => "x"})
      | lsn: 1
    }

    Worker.run(event)

    assert {:ok, [message], _} =
             RestdisElectric.Log.read("tenant1", "h1", RestdisElectric.Offset.beginning())

    assert message.value == %{"id" => 3, "active" => true, "name" => "x"}
  end

  test "start_link/1 starts a supervised task that runs the event" do
    event = TestUtils.insert_event("unknown_table")
    assert {:ok, pid} = Worker.start_link(event)
    assert is_pid(pid)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 500
  end

  test "unhandled event op is a no-op" do
    event = %RestdisBuster.WAL.Event{op: nil, schema: "public", table: "products"}
    assert :ok = Worker.run(event)
  end

  test "DML event with an already-integer PK is not re-coerced" do
    config = %{
      tenant_id: "tenant1",
      schema: "public",
      table_name: "products",
      pk_column: "id",
      mode: "ttl"
    }

    seed_config("public", "products", config)
    on_exit(&clear_config/0)

    event = %RestdisBuster.WAL.Event{
      op: :update,
      schema: "public",
      table: "products",
      new_row: %{"id" => 42},
      received_at: System.monotonic_time(:microsecond)
    }

    assert :ok = Worker.run(event)
  end

  describe ":message events (DDL notifications)" do
    defmodule DdlStubHandler do
      @behaviour Restdis.Wal.Handler

      @impl Restdis.Wal.Handler
      def invalidate_by_row(_tenant_id, _table, _pk), do: :ok

      @impl Restdis.Wal.Handler
      def flush_table(tenant_id, table) do
        send(:worker_test, {:flush_table, tenant_id, table})
        :ok
      end
    end

    # The file-level `setup` above already registers the test process as
    # `:worker_test`; reuse that name here rather than registering a second
    # one (a process can only hold a single registered name at a time).
    setup do
      Application.put_env(:restdis_buster, :wal_handler, DdlStubHandler)
      on_exit(fn -> Application.delete_env(:restdis_buster, :wal_handler) end)
      :ok
    end

    test "a drop DDL message for a configured table flushes it" do
      config = %{
        tenant_id: "tenant1",
        schema: "public",
        table_name: "products",
        pk_column: "id",
        mode: "ttl"
      }

      seed_config("public", "products", config)
      on_exit(&clear_config/0)

      event = %RestdisBuster.WAL.Event{
        op: :message,
        new_row: %{
          prefix: "restdis_ddl",
          content: Jason.encode!(%{"op" => "drop", "schema" => "public", "table" => "products"})
        }
      }

      assert :ok = Worker.run(event)
      assert_receive {:flush_table, "tenant1", "products"}, 200
    end

    test "a drop DDL message for an unconfigured table is a no-op" do
      event = %RestdisBuster.WAL.Event{
        op: :message,
        new_row: %{
          prefix: "restdis_ddl",
          content: Jason.encode!(%{"op" => "drop", "schema" => "public", "table" => "no_such"})
        }
      }

      assert :ok = Worker.run(event)
      refute_receive {:flush_table, _, _}, 100
    end

    test "a non-drop DDL message is a no-op" do
      event = %RestdisBuster.WAL.Event{
        op: :message,
        new_row: %{
          prefix: "restdis_ddl",
          content: Jason.encode!(%{"op" => "create", "schema" => "public", "table" => "products"})
        }
      }

      assert :ok = Worker.run(event)
      refute_receive {:flush_table, _, _}, 100
    end

    test "a message with unparseable JSON content is a no-op" do
      event = %RestdisBuster.WAL.Event{
        op: :message,
        new_row: %{prefix: "restdis_ddl", content: "not json"}
      }

      assert :ok = Worker.run(event)
      refute_receive {:flush_table, _, _}, 100
    end

    test "a message without the restdis_ddl prefix is a no-op" do
      event = %RestdisBuster.WAL.Event{op: :message, new_row: %{prefix: "other", content: "{}"}}
      assert :ok = Worker.run(event)
      refute_receive {:flush_table, _, _}, 100
    end
  end

  test "DML event for a replication-mode table casts fallback/boolean-false/unparseable values" do
    config = %{
      tenant_id: "tenant1",
      schema: "public",
      table_name: "widgets2",
      pk_column: "id",
      mode: "replication"
    }

    seed_config("public", "widgets2", config)
    on_exit(&clear_config/0)

    Application.put_env(:restdis_electric, :tables, %{
      "public.widgets2" => %{
        columns: ["id", "active", "count", "price", "flag", "name"],
        primary_key: ["id"],
        types: %{
          "id" => "integer",
          "active" => "boolean",
          "count" => "bigint",
          "price" => "numeric",
          "flag" => "boolean",
          "name" => "text"
        }
      }
    })

    on_exit(fn -> Application.delete_env(:restdis_electric, :tables) end)

    case RestdisElectric.Supervisor.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok = RestdisElectric.ShapeRegistry.register("tenant1", "public", "widgets2", "h2")

    event = %{
      TestUtils.insert_event("widgets2", "public", %{
        "id" => "not-an-int",
        "active" => "f",
        "count" => "not-a-number",
        "price" => "not-a-float",
        "flag" => "maybe",
        "name" => "x"
      })
      | lsn: 1
    }

    Worker.run(event)

    assert {:ok, [message], _} =
             RestdisElectric.Log.read("tenant1", "h2", RestdisElectric.Offset.beginning())

    assert message.value == %{
             "id" => "not-an-int",
             "active" => false,
             "count" => "not-a-number",
             "price" => "not-a-float",
             "flag" => "maybe",
             "name" => "x"
           }
  end

  test "config table flush does not affect a different table's cache" do
    config = %{
      tenant_id: "tenant2",
      schema: "public",
      table_name: "orders",
      pk_column: "order_id",
      mode: "ttl"
    }

    seed_config("public", "orders", config)
    on_exit(&clear_config/0)

    key = Key.build(:table, "orders", %{})
    Restdis.Cache.put("tenant2", key, %{"order_id" => 99}, primary_keys: [99])

    # Flush 'products' table config — should not touch 'orders' cache
    event = %RestdisBuster.WAL.Event{
      op: :update,
      schema: "public",
      table: "tenant_table_config",
      new_row: %{"tenant_id" => "tenant1", "schema" => "public", "table_name" => "products"}
    }

    Worker.run(event)
    assert {:ok, _} = Restdis.Cache.peek("tenant2", key)
  end
end
