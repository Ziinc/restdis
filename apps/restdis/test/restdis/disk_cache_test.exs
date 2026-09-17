defmodule Restdis.Cache.DiskCacheTest do
  use ExUnit.Case, async: false

  alias Restdis.Cache.DiskCache
  alias Restdis.Cache.InstanceConfig
  alias Restdis.Cache.Key
  alias Restdis.Cache.TenantSupervisor

  setup do
    tenant_id = "dc_#{System.unique_integer([:positive])}"
    TenantSupervisor.ensure_started(Restdis.Cache, tenant_id)
    on_exit(fn -> Restdis.Cache.flush_tenant(tenant_id) end)
    {:ok, tenant_id: tenant_id}
  end

  test "put and get returns value", %{tenant_id: tenant_id} do
    key = Key.build(:table, "products", %{})
    value = [%{"id" => 1}, %{"id" => 2}]

    DiskCache.put(tenant_id, key, value, name: Restdis.Cache)
    assert {:ok, ^value} = DiskCache.get(Restdis.Cache, tenant_id, key)
  end

  test "get returns miss for unknown key", %{tenant_id: tenant_id} do
    key = Key.build(:table, "missing", %{})
    assert :miss = DiskCache.get(Restdis.Cache, tenant_id, key)
  end

  test "delete removes value", %{tenant_id: tenant_id} do
    key = Key.build(:table, "products", %{})
    DiskCache.put(tenant_id, key, "val", name: Restdis.Cache)
    DiskCache.delete(Restdis.Cache, tenant_id, key)
    assert :miss = DiskCache.get(Restdis.Cache, tenant_id, key)
  end

  test "stores and retrieves complex Elixir terms", %{tenant_id: tenant_id} do
    key = Key.build(:rpc, "my_fn", %{"arg" => "x"})
    value = %{nested: [1, 2, %{deep: true}], atom_key: :ok}

    DiskCache.put(tenant_id, key, value, name: Restdis.Cache)
    assert {:ok, ^value} = DiskCache.get(Restdis.Cache, tenant_id, key)
  end

  test "persisted_entries/1 returns [] when the disk cache is not running" do
    tenant_id = "dc_never_started_#{System.unique_integer([:positive])}"
    assert DiskCache.persisted_entries(Restdis.Cache, tenant_id) == []
  end

  test "persisted_entries/1 returns only entries flagged persist: true", %{
    tenant_id: tenant_id
  } do
    persisted_key = Key.build(:table, "persisted", %{})
    plain_key = Key.build(:table, "plain", %{})

    DiskCache.put(tenant_id, persisted_key, "persisted-value", persist: true, name: Restdis.Cache)
    DiskCache.put(tenant_id, plain_key, "plain-value", name: Restdis.Cache)

    assert [{^persisted_key, "persisted-value"}] =
             DiskCache.persisted_entries(Restdis.Cache, tenant_id)
  end

  test "set_persist/3 returns :not_found for a missing key", %{tenant_id: tenant_id} do
    key = Key.build(:table, "missing", %{})
    assert :not_found = DiskCache.set_persist(Restdis.Cache, tenant_id, key, true)
  end

  test "get_with_ttl returns the remaining ttl for a ttl-bearing entry", %{tenant_id: tenant_id} do
    key = Key.build(:table, "products", %{})
    value = [%{"id" => 1}]

    DiskCache.put(tenant_id, key, value, ttl_ms: 60_000, name: Restdis.Cache)

    assert {:ok, ^value, ttl_ms} = DiskCache.get_with_ttl(Restdis.Cache, tenant_id, key)
    assert is_integer(ttl_ms)
    assert ttl_ms > 0 and ttl_ms <= 60_000
  end

  test "get_with_ttl returns nil ttl for an entry stored without ttl_ms", %{
    tenant_id: tenant_id
  } do
    key = Key.build(:table, "products", %{})
    DiskCache.put(tenant_id, key, "val", name: Restdis.Cache)

    assert {:ok, "val", nil} = DiskCache.get_with_ttl(Restdis.Cache, tenant_id, key)
  end

  test "get treats an expired ttl_ms entry as a miss and removes it", %{tenant_id: tenant_id} do
    key = Key.build(:table, "products", %{})
    DiskCache.put(tenant_id, key, "val", ttl_ms: -1, name: Restdis.Cache)

    assert :miss = DiskCache.get(Restdis.Cache, tenant_id, key)
    assert :miss = DiskCache.get_with_ttl(Restdis.Cache, tenant_id, key)
  end

  test "over-cap put with nothing evictable keeps every persisted entry", %{
    tenant_id: tenant_id
  } do
    key1 = Key.build(:table, "cap1", %{})
    key2 = Key.build(:table, "cap2", %{})
    value = String.duplicate("z", 500)

    DiskCache.put(tenant_id, key1, value, persist: true, name: Restdis.Cache)
    size_after_one = DiskCache.disk_size_bytes(Restdis.Cache, tenant_id)

    previous = InstanceConfig.get(Restdis.Cache, :cubdb_cap_bytes)
    InstanceConfig.put_field(Restdis.Cache, :cubdb_cap_bytes, size_after_one)

    on_exit(fn ->
      InstanceConfig.put_field(Restdis.Cache, :cubdb_cap_bytes, previous)
    end)

    DiskCache.put(tenant_id, key2, value, persist: true, name: Restdis.Cache)

    assert {:ok, ^value} = DiskCache.get(Restdis.Cache, tenant_id, key1)
    assert {:ok, ^value} = DiskCache.get(Restdis.Cache, tenant_id, key2)
  end
end
