defmodule Restdis.Cache.InvalidateListsTest do
  use ExUnit.Case, async: false

  alias Restdis.Cache.Key
  alias Restdis.Cache.TenantSupervisor

  setup do
    tenant_id = "il_#{System.unique_integer([:positive])}"
    TenantSupervisor.ensure_started(Restdis.Cache, tenant_id)
    on_exit(fn -> Restdis.Cache.flush_tenant(tenant_id) end)
    {:ok, tenant_id: tenant_id}
  end

  test "invalidate_lists/2 removes list-scoped keys but leaves single-row keys", %{
    tenant_id: t
  } do
    list_key = Key.build(:table, "a", %{})
    single_key = Key.build(:table, "a", %{"id" => "eq.1"})

    Restdis.Cache.put(t, list_key, [%{"id" => 1}, %{"id" => 2}], primary_keys: [1, 2])
    Restdis.Cache.put(t, single_key, %{"id" => 1}, primary_keys: [1])

    Restdis.Cache.invalidate_lists(t, "a")

    assert :miss == Restdis.Cache.peek(t, list_key)
    assert {:ok, _} = Restdis.Cache.peek(t, single_key)
  end

  test "invalidate_lists/2 does not affect list keys from a different table", %{tenant_id: t} do
    key_keep = Key.build(:table, "orders", %{})
    Restdis.Cache.put(t, key_keep, [%{"id" => 5}], primary_keys: [5])

    Restdis.Cache.invalidate_lists(t, "products")

    assert {:ok, _} = Restdis.Cache.peek(t, key_keep)
  end

  test "invalidate_lists/2 is a no-op for a table with no cached lists", %{tenant_id: t} do
    assert :ok = Restdis.Cache.invalidate_lists(t, "nonexistent")
  end

  test "invalidate_lists/2 is a no-op for an unstarted tenant" do
    assert :ok = Restdis.Cache.invalidate_lists("fresh-tenant-#{System.unique_integer()}", "any")
  end
end
