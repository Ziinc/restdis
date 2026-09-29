defmodule Restdis.Cache.HotCacheInvalidationTest do
  use ExUnit.Case, async: false

  alias Restdis.Cache.DiskCache
  alias Restdis.Cache.HotCache
  alias Restdis.Cache.InstanceConfig
  alias Restdis.Cache.Key
  alias Restdis.Cache.QueryCache
  alias Restdis.Cache.Router
  alias Restdis.Cache.TestUtils

  setup do
    tenant_id = TestUtils.start_tenant("hot_inv")

    on_exit(fn ->
      Restdis.Cache.flush_tenant(tenant_id)
      HotCache.flush()
    end)

    {:ok, tenant_id: tenant_id}
  end

  test "a hot entry does not outlive the underlying entry's TTL", %{tenant_id: t} do
    key = Key.build(:table, "widgets", %{"id" => "eq.7"})
    :ok = Restdis.Cache.put(t, key, %{"id" => 7}, ttl_ms: 50)

    assert {:ok, %{"id" => 7}} = Router.get(t, key)
    Process.sleep(100)

    assert :miss = Router.get(t, key)
  end

  test "invalidate_lists/3 clears the hot entry of a cached list", %{tenant_id: t} do
    key = Key.build(:table, "widgets", %{"id" => "gt.48"})
    :ok = Restdis.Cache.put(t, key, [%{"id" => 49}, %{"id" => 50}])
    assert {:ok, _} = Router.get(t, key)

    :ok = Restdis.Cache.invalidate_lists(t, "widgets")

    assert :miss = HotCache.get(t, key)
    assert :miss = Router.get(t, key)
  end

  test "flush_table/3 clears the hot entry", %{tenant_id: t} do
    key = Key.build(:table, "widgets", %{"id" => "eq.1"})
    :ok = Restdis.Cache.put(t, key, %{"id" => 1})
    assert {:ok, _} = Router.get(t, key)

    :ok = Restdis.Cache.flush_table(t, "widgets")

    assert :miss = HotCache.get(t, key)
  end

  test "flush_tenant/2 clears every hot entry of the tenant only", %{tenant_id: t} do
    other = TestUtils.start_tenant("hot_inv_other")
    on_exit(fn -> Restdis.Cache.flush_tenant(other) end)
    key1 = Key.build(:table, "widgets", %{"id" => "eq.1"})
    key2 = Key.build(:table, "gadgets", %{"id" => "eq.2"})

    for tenant <- [t, other], key <- [key1, key2] do
      :ok = Restdis.Cache.put(tenant, key, "v")
      assert {:ok, "v"} = Router.get(tenant, key)
    end

    :ok = Restdis.Cache.flush_tenant(t)

    assert :miss = HotCache.get(t, key1)
    assert :miss = HotCache.get(t, key2)
    assert {:ok, "v"} = HotCache.get(other, key1)
    assert {:ok, "v"} = HotCache.get(other, key2)
  end

  test "an ETS eviction clears the evicted key's hot entry", %{tenant_id: t} do
    key1 = Key.build(:table, "evict", %{"a" => 1})
    key2 = Key.build(:table, "evict", %{"a" => 2})
    value = String.duplicate("x", 1000)
    :ok = Restdis.Cache.put(t, key1, value)
    assert {:ok, ^value} = Router.get(t, key1)

    previous = InstanceConfig.get(Restdis.Cache, :ets_cap_bytes)
    InstanceConfig.put_field(Restdis.Cache, :ets_cap_bytes, 1)
    on_exit(fn -> InstanceConfig.put_field(Restdis.Cache, :ets_cap_bytes, previous) end)

    QueryCache.put(t, key2, value, name: Restdis.Cache)

    assert :miss = HotCache.get(t, key1)
  end

  test "a CubDB eviction clears the evicted key's hot entry", %{tenant_id: t} do
    key1 = Key.build(:table, "evict", %{"a" => 1})
    key2 = Key.build(:table, "evict", %{"a" => 2})
    value = String.duplicate("x", 1000)
    :ok = Restdis.Cache.put(t, key1, value)
    assert {:ok, ^value} = Router.get(t, key1)

    previous = InstanceConfig.get(Restdis.Cache, :cubdb_cap_bytes)
    InstanceConfig.put_field(Restdis.Cache, :cubdb_cap_bytes, 1)
    on_exit(fn -> InstanceConfig.put_field(Restdis.Cache, :cubdb_cap_bytes, previous) end)

    DiskCache.put(t, key2, value, name: Restdis.Cache)

    assert :miss = HotCache.get(t, key1)
  end
end
