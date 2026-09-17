defmodule Restdis.Cache.QueryCacheTest do
  use ExUnit.Case, async: false

  alias Restdis.Cache.Key
  alias Restdis.Cache.QueryCache
  alias Restdis.Cache.TenantRegistry
  alias Restdis.Cache.TenantSupervisor

  setup do
    tenant_id = "qc_#{System.unique_integer([:positive])}"
    TenantSupervisor.ensure_started(Restdis.Cache, tenant_id)
    on_exit(fn -> Restdis.Cache.flush_tenant(tenant_id) end)
    {:ok, tenant_id: tenant_id}
  end

  test "put and get returns value", %{tenant_id: tenant_id} do
    key = Key.build(:table, "products", %{"select" => "id,name"})
    value = %{"id" => 1, "name" => "Widget"}

    QueryCache.put(tenant_id, key, value, name: Restdis.Cache)
    assert {:ok, ^value} = QueryCache.get(Restdis.Cache, tenant_id, key)
  end

  test "get returns miss for unknown key", %{tenant_id: tenant_id} do
    key = Key.build(:table, "products", %{})
    assert :miss = QueryCache.get(Restdis.Cache, tenant_id, key)
  end

  test "delete removes value", %{tenant_id: tenant_id} do
    key = Key.build(:table, "products", %{})
    QueryCache.put(tenant_id, key, "value", name: Restdis.Cache)
    QueryCache.delete(Restdis.Cache, tenant_id, key)
    assert :miss = QueryCache.get(Restdis.Cache, tenant_id, key)
  end

  test "key canonicalization: same params in any order produce the same key" do
    key1 = Key.build(:table, "products", %{"b" => 2, "a" => 1})
    key2 = Key.build(:table, "products", %{"a" => 1, "b" => 2})
    assert key1 == key2
  end

  test "keys with different params do not collide" do
    key1 = Key.build(:table, "products", %{"id" => "eq.1"})
    key2 = Key.build(:table, "products", %{"id" => "eq.2"})
    assert key1 != key2
  end

  test "get treats an entry past its ttl as a miss and removes it", %{tenant_id: tenant_id} do
    key = Key.build(:table, "products", %{})
    QueryCache.put(tenant_id, key, "value", ttl_ms: 1, name: Restdis.Cache)

    Process.sleep(5)

    assert :miss = QueryCache.get(Restdis.Cache, tenant_id, key)
    assert :miss = QueryCache.get(Restdis.Cache, tenant_id, key)
  end

  test "get returns an unexpired ttl entry and refreshes its last-access time", %{
    tenant_id: tenant_id
  } do
    key = Key.build(:table, "products", %{})
    QueryCache.put(tenant_id, key, "value", ttl_ms: 60_000, name: Restdis.Cache)

    assert {:ok, "value"} = QueryCache.get(Restdis.Cache, tenant_id, key)
  end

  test "the periodic sweep removes expired entries", %{tenant_id: tenant_id} do
    key = Key.build(:table, "products", %{})
    QueryCache.put(tenant_id, key, "value", ttl_ms: 1, name: Restdis.Cache)
    Process.sleep(5)

    pid = TenantRegistry.whereis(Restdis.Cache, tenant_id, :query_cache)
    send(pid, :sweep)
    :sys.get_state(pid)

    assert :miss = QueryCache.get(Restdis.Cache, tenant_id, key)
  end

  test "stopping the tenant clears the query cache's registered table, not just the process", %{
    tenant_id: tenant_id
  } do
    assert TenantRegistry.get_value(Restdis.Cache, tenant_id, :qc_table)
    assert TenantRegistry.get_value(Restdis.Cache, tenant_id, :qc_persist)

    pid = TenantRegistry.whereis(Restdis.Cache, tenant_id, :tenant)
    ref = Process.monitor(pid)
    Supervisor.stop(pid, :normal)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

    # Registry clears a dead process's entries via its own async monitor, so poll briefly.
    assert_eventually(fn -> TenantRegistry.whereis(Restdis.Cache, tenant_id, :query_cache) end)
    assert_eventually(fn -> TenantRegistry.get_value(Restdis.Cache, tenant_id, :qc_table) end)
    assert_eventually(fn -> TenantRegistry.get_value(Restdis.Cache, tenant_id, :qc_persist) end)
  end

  defp assert_eventually(fun, attempts \\ 20) do
    if attempts <= 0 do
      refute fun.()
    else
      if fun.() do
        Process.sleep(10)
        assert_eventually(fun, attempts - 1)
      else
        refute fun.()
      end
    end
  end
end
