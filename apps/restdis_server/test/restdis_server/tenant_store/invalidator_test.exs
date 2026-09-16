defmodule RestdisServer.TenantStore.InvalidatorTest do
  use ExUnit.Case, async: false

  alias RestdisServer.TenantConfig
  alias RestdisServer.TenantStore.InMemory
  alias RestdisServer.TenantStore.Invalidator

  @tenant_id "tenant_invalidator_test"

  setup do
    InMemory.seed([
      %{
        api_key: "sk_invalidator",
        tenant_id: @tenant_id,
        default_ttl_s: 60,
        persist_cap: 50_000,
        pgrst_base_url: "http://localhost",
        pgrst_api_key: "pgrst",
        replica_url: nil
      }
    ])

    on_exit(fn -> InMemory.clear() end)
    :ok
  end

  test "invalidate/1 drops the cached tenant config" do
    assert {:ok, _} = TenantConfig.lookup_by_tenant_id(@tenant_id)

    InMemory.clear()
    assert :ok = Invalidator.invalidate(@tenant_id)

    assert {:error, :not_found} = TenantConfig.lookup_by_tenant_id(@tenant_id)
  end

  test "invalidate/1 does not raise for a tenant with no active rewarms" do
    assert :ok = Invalidator.invalidate("tenant_with_no_rewarms")
  end
end
