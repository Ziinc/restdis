defmodule Restdis.Cache.DiskCacheTest do
  use ExUnit.Case, async: false

  alias Restdis.Cache.DiskCache
  alias Restdis.Cache.Key
  alias Restdis.Cache.TenantSupervisor

  setup do
    tenant_id = "dc_#{System.unique_integer([:positive])}"
    TenantSupervisor.ensure_started(tenant_id)
    on_exit(fn -> Restdis.Cache.flush_tenant(tenant_id) end)
    {:ok, tenant_id: tenant_id}
  end

  test "put and get returns value", %{tenant_id: tenant_id} do
    key = Key.build(:table, "products", %{})
    value = [%{"id" => 1}, %{"id" => 2}]

    DiskCache.put(tenant_id, key, value)
    assert {:ok, ^value} = DiskCache.get(tenant_id, key)
  end

  test "get returns miss for unknown key", %{tenant_id: tenant_id} do
    key = Key.build(:table, "missing", %{})
    assert :miss = DiskCache.get(tenant_id, key)
  end

  test "delete removes value", %{tenant_id: tenant_id} do
    key = Key.build(:table, "products", %{})
    DiskCache.put(tenant_id, key, "val")
    DiskCache.delete(tenant_id, key)
    # delete is async (cast); flush pending messages via a synchronous call
    DiskCache.get(tenant_id, Key.build(:table, "_sync", %{}))
    assert :miss = DiskCache.get(tenant_id, key)
  end

  test "stores and retrieves complex Elixir terms", %{tenant_id: tenant_id} do
    key = Key.build(:rpc, "my_fn", %{"arg" => "x"})
    value = %{nested: [1, 2, %{deep: true}], atom_key: :ok}

    DiskCache.put(tenant_id, key, value)
    assert {:ok, ^value} = DiskCache.get(tenant_id, key)
  end
end
