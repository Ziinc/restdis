defmodule SupaCacherBuster.WorkerTest do
  use ExUnit.Case, async: false

  alias Restdis.Cache.Key
  alias Restdis.Cache.TenantSupervisor
  alias SupaCacherBuster.TestUtils
  alias SupaCacherBuster.Worker

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
    Application.put_env(:supa_cacher_buster, :tenant_config_invalidator, StubInvalidator)
    on_exit(fn -> Application.put_env(:supa_cacher_buster, :tenant_config_invalidator, nil) end)

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

    event = %SupaCacherBuster.WAL.Event{
      op: :update,
      schema: "public",
      table: "tenant_table_config",
      new_row: %{"tenant_id" => "tenant1", "schema" => "public", "table_name" => "products"}
    }

    Worker.run(event)
    assert :miss = Restdis.Cache.peek("tenant1", key)
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
    event = %SupaCacherBuster.WAL.Event{
      op: :update,
      schema: "public",
      table: "tenant_table_config",
      new_row: %{"tenant_id" => "tenant1", "schema" => "public", "table_name" => "products"}
    }

    Worker.run(event)
    assert {:ok, _} = Restdis.Cache.peek("tenant2", key)
  end
end
