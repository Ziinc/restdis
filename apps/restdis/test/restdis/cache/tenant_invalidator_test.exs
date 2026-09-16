defmodule Restdis.Cache.TenantInvalidatorTest do
  use ExUnit.Case, async: false

  alias Restdis.Cache.Key
  alias Restdis.Cache.QueryCache
  alias Restdis.Cache.TenantInvalidator
  alias Restdis.Cache.TenantRegistry
  alias Restdis.Cache.TenantSupervisor

  test "invalidate/1 flushes every cache layer for the tenant" do
    tenant_id = "ti_#{System.unique_integer([:positive])}"
    TenantSupervisor.ensure_started(Restdis.Cache, tenant_id)

    key = Key.build(:table, "products", %{})
    QueryCache.put(Restdis.Cache, tenant_id, key, "value")
    assert {:ok, "value"} = QueryCache.get(Restdis.Cache, tenant_id, key)

    assert :ok = TenantInvalidator.invalidate(tenant_id)

    refute TenantRegistry.whereis(Restdis.Cache, tenant_id, :tenant)
  end
end
