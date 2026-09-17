defmodule Restdis.Cache.Cluster.MigrationTest do
  use ExUnit.Case, async: false

  alias Restdis.Cache.Cluster.HashRing
  alias Restdis.Cache.Cluster.Migration
  alias Restdis.Cache.Key
  alias Restdis.Cache.TenantRegistry
  alias Restdis.Cache.TestUtils

  @ghost :"ghost@127.0.0.1"

  test "a tenant still owned locally is left running" do
    tenant_id = TestUtils.start_tenant("mig")
    on_exit(fn -> Restdis.Cache.flush_tenant(tenant_id) end)

    ring = HashRing.new([Node.self()])

    assert Migration.rebalance(ring) == []
    assert TenantRegistry.whereis(Restdis.Cache, tenant_id, :tenant)
  end

  test "a tenant whose new owner is unreachable keeps serving locally" do
    tenant_id = TestUtils.start_tenant("mig")
    on_exit(fn -> Restdis.Cache.flush_tenant(tenant_id) end)

    key = Key.build(:table, "widgets", %{})
    assert :ok = Restdis.Cache.put(tenant_id, key, "v", persist: true)

    ring = HashRing.new([@ghost])

    assert Migration.rebalance(ring) == []
    assert TenantRegistry.whereis(Restdis.Cache, tenant_id, :tenant)
    assert {:ok, "v"} = Restdis.Cache.peek(tenant_id, key)
  end

  test "local_tenants/0 lists the running tenant aggregates" do
    tenant_id = TestUtils.start_tenant("mig")
    on_exit(fn -> Restdis.Cache.flush_tenant(tenant_id) end)

    assert tenant_id in TenantRegistry.local_tenants(Restdis.Cache)
  end
end
