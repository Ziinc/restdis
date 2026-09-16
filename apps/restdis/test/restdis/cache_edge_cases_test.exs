defmodule Restdis.CacheEdgeCasesTest do
  use ExUnit.Case, async: false

  alias Restdis.Cache
  alias Restdis.Cache.Key
  alias Restdis.Cache.TenantSupervisor

  test "flush_tenant/1 is a no-op for a tenant with no running aggregate" do
    tenant_id = "no_such_tenant_#{System.unique_integer([:positive])}"
    assert Cache.flush_tenant(tenant_id) == :ok
  end

  test "persist_count/1 is 0 for a tenant that never persisted anything" do
    tenant_id = "pc_#{System.unique_integer([:positive])}"
    TenantSupervisor.ensure_started(Restdis.Cache, tenant_id)
    on_exit(fn -> Cache.flush_tenant(tenant_id) end)

    assert Cache.persist_count(tenant_id) == 0
  end

  test "persist_count/1 is 0 for a tenant with no running aggregate at all" do
    tenant_id = "pc_never_started_#{System.unique_integer([:positive])}"
    assert Cache.persist_count(tenant_id) == 0
  end

  test "put/4 with :persist returns {:error, :persist_cap} once the cap is reached" do
    tenant_id = "cap_#{System.unique_integer([:positive])}"
    TenantSupervisor.ensure_started(Restdis.Cache, tenant_id)
    on_exit(fn -> Cache.flush_tenant(tenant_id) end)

    key1 = Key.build(:table, "capped1", %{})
    key2 = Key.build(:table, "capped2", %{})

    assert :ok = Cache.put(tenant_id, key1, "v1", persist: true, persist_cap: 1)

    assert {:error, :persist_cap} =
             Cache.put(tenant_id, key2, "v2", persist: true, persist_cap: 1)

    assert Cache.persist_count(tenant_id) == 1
  end
end
