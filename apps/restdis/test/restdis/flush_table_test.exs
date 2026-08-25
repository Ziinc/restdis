defmodule Restdis.Cache.FlushTableTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Restdis.Cache.Key
  alias Restdis.Cache.TenantSupervisor

  setup do
    tenant_id = "ft_#{System.unique_integer([:positive])}"
    TenantSupervisor.ensure_started(tenant_id)
    on_exit(fn -> Restdis.Cache.flush_tenant(tenant_id) end)
    {:ok, tenant_id: tenant_id}
  end

  test "flush_table/2 removes all keys for the given table", %{tenant_id: t} do
    key_a1 = Key.build(:table, "a", %{"select" => "id"})
    key_a2 = Key.build(:table, "a", %{"select" => "name"})
    key_b = Key.build(:table, "b", %{})

    Restdis.Cache.put(t, key_a1, %{"id" => 1}, primary_keys: [1])
    Restdis.Cache.put(t, key_a2, %{"name" => "x"}, primary_keys: [1])
    Restdis.Cache.put(t, key_b, %{"id" => 2}, primary_keys: [2])

    Restdis.Cache.flush_table(t, "a")

    assert :miss == Restdis.Cache.peek(t, key_a1)
    assert :miss == Restdis.Cache.peek(t, key_a2)
    assert {:ok, _} = Restdis.Cache.peek(t, key_b)
  end

  test "flush_table/2 is a no-op for a table with no cached entries", %{tenant_id: t} do
    assert :ok = Restdis.Cache.flush_table(t, "nonexistent")
  end

  test "flush_table/2 is a no-op for an unstarted tenant" do
    assert :ok = Restdis.Cache.flush_table("fresh-tenant-#{System.unique_integer()}", "any")
  end

  test "flush_table/2 does not affect keys from a different table", %{tenant_id: t} do
    key_keep = Key.build(:table, "orders", %{})
    Restdis.Cache.put(t, key_keep, %{"id" => 5}, primary_keys: [5])

    Restdis.Cache.flush_table(t, "products")

    assert {:ok, _} = Restdis.Cache.peek(t, key_keep)
  end

  property "flush_table/2 leaves only keys for tables not in the flush set", %{tenant_id: t} do
    check all(
            pks_a <- list_of(positive_integer(), min_length: 1, max_length: 5),
            pks_b <- list_of(positive_integer(), min_length: 1, max_length: 5)
          ) do
      key_a = Key.build(:table, "prop_a", %{})
      key_b = Key.build(:table, "prop_b", %{})

      Restdis.Cache.put(t, key_a, Enum.map(pks_a, &%{"id" => &1}), primary_keys: pks_a)
      Restdis.Cache.put(t, key_b, Enum.map(pks_b, &%{"id" => &1}), primary_keys: pks_b)

      Restdis.Cache.flush_table(t, "prop_a")

      assert :miss == Restdis.Cache.peek(t, key_a)
      assert {:ok, _} = Restdis.Cache.peek(t, key_b)

      # cleanup for next iteration
      Restdis.Cache.delete(t, key_b)
    end
  end
end
