defmodule Restdis.Cache.PropertyTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Restdis.Cache.Key
  alias Restdis.Cache.TenantSupervisor

  setup do
    tenant_id = "prop_#{System.unique_integer([:positive])}"
    TenantSupervisor.ensure_started(Restdis.Cache, tenant_id)
    on_exit(fn -> Restdis.Cache.flush_tenant(tenant_id) end)
    {:ok, tenant_id: tenant_id}
  end

  property "get after put returns the put value", %{tenant_id: tenant_id} do
    check all(
            ident <- string(:alphanumeric, min_length: 1),
            params <- map_of(string(:alphanumeric, min_length: 1), integer()),
            value <- one_of([integer(), string(:printable), list_of(integer())])
          ) do
      key = Key.build(:table, ident, params)
      Restdis.Cache.put(tenant_id, key, value)
      assert {:ok, ^value} = Restdis.Cache.get(tenant_id, key)
    end
  end

  property "get after delete returns miss", %{tenant_id: tenant_id} do
    check all(
            ident <- string(:alphanumeric, min_length: 1),
            params <- map_of(string(:alphanumeric, min_length: 1), integer()),
            value <- one_of([integer(), string(:printable)])
          ) do
      key = Key.build(:table, ident, params)
      Restdis.Cache.put(tenant_id, key, value)
      Restdis.Cache.delete(tenant_id, key)
      # delete is async for disk layer; flush via a get
      Process.sleep(10)
      assert :miss = Restdis.Cache.get(tenant_id, key)
    end
  end
end
