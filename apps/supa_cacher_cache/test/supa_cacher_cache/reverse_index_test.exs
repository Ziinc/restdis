defmodule SupaCacherCache.ReverseIndexTest do
  use ExUnit.Case, async: false

  alias SupaCacherCache.Key
  alias SupaCacherCache.ReverseIndex
  alias SupaCacherCache.TenantSupervisor

  setup do
    tenant_id = "ri_#{System.unique_integer([:positive])}"
    TenantSupervisor.ensure_started(tenant_id)
    on_exit(fn -> SupaCacherCache.flush_tenant(tenant_id) end)
    {:ok, tenant_id: tenant_id}
  end

  test "add and purge_row returns the indexed cache key", %{tenant_id: tenant_id} do
    key = Key.build(:table, "products", %{})
    ReverseIndex.add(tenant_id, "products", 1, key)
    # flush async add via a sync call
    ReverseIndex.purge_row(tenant_id, "products", 999)

    keys = ReverseIndex.purge_row(tenant_id, "products", 1)
    assert key in keys
  end

  test "array result: one index entry per primary key", %{tenant_id: tenant_id} do
    key = Key.build(:table, "products", %{})
    value = [%{"id" => 10}, %{"id" => 20}, %{"id" => 30}]

    SupaCacherCache.put(tenant_id, key, value)

    Enum.each([10, 20, 30], fn pk ->
      keys = ReverseIndex.purge_row(tenant_id, "products", pk)
      assert key in keys, "expected key to be indexed for pk=#{pk}"
    end)
  end

  test "purge_key removes entries from forward index", %{tenant_id: tenant_id} do
    key = Key.build(:table, "orders", %{})
    ReverseIndex.add(tenant_id, "orders", 99, key)
    ReverseIndex.purge_row(tenant_id, "orders", 0)

    ReverseIndex.purge_key(tenant_id, key)
    # flush purge_key (cast) via sync call
    ReverseIndex.purge_row(tenant_id, "orders", 0)

    assert [] = ReverseIndex.purge_row(tenant_id, "orders", 99)
  end

  test "multiple keys per row are all returned by purge_row", %{tenant_id: tenant_id} do
    key1 = Key.build(:table, "products", %{"select" => "id"})
    key2 = Key.build(:table, "products", %{"select" => "id,name"})

    ReverseIndex.add(tenant_id, "products", 5, key1)
    ReverseIndex.add(tenant_id, "products", 5, key2)
    ReverseIndex.purge_row(tenant_id, "products", 0)

    keys = ReverseIndex.purge_row(tenant_id, "products", 5)
    assert key1 in keys
    assert key2 in keys
  end
end
