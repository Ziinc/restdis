defmodule SupaCacherCache.QueryCacheTest do
  use ExUnit.Case, async: false

  alias SupaCacherCache.Key
  alias SupaCacherCache.QueryCache
  alias SupaCacherCache.TenantSupervisor

  setup do
    tenant_id = "qc_#{System.unique_integer([:positive])}"
    TenantSupervisor.ensure_started(tenant_id)
    on_exit(fn -> SupaCacherCache.flush_tenant(tenant_id) end)
    {:ok, tenant_id: tenant_id}
  end

  test "put and get returns value", %{tenant_id: tenant_id} do
    key = Key.build(:table, "products", %{"select" => "id,name"})
    value = %{"id" => 1, "name" => "Widget"}

    QueryCache.put(tenant_id, key, value)
    assert {:ok, ^value} = QueryCache.get(tenant_id, key)
  end

  test "get returns miss for unknown key", %{tenant_id: tenant_id} do
    key = Key.build(:table, "products", %{})
    assert :miss = QueryCache.get(tenant_id, key)
  end

  test "delete removes value", %{tenant_id: tenant_id} do
    key = Key.build(:table, "products", %{})
    QueryCache.put(tenant_id, key, "value")
    QueryCache.delete(tenant_id, key)
    assert :miss = QueryCache.get(tenant_id, key)
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
end
