defmodule RestdisServer.TenantConfigTest do
  use ExUnit.Case, async: false

  alias Restdis.Cache.QueryCache
  alias Restdis.Cache.ReadThrough
  alias RestdisServer.TenantConfig
  alias RestdisServer.TenantStore.InMemory

  @tenant %{
    tenant_id: "acme",
    api_key: "key-acme",
    default_ttl_s: 60,
    persist_cap: 10,
    pgrst_base_url: "http://localhost",
    pgrst_api_key: "pgrst",
    replica_url: nil
  }

  setup do
    InMemory.seed([@tenant])
    TenantConfig.invalidate("acme")
    on_exit(fn -> InMemory.clear() end)
    :ok
  end

  test "lookup_by_tenant_id/1 returns the stored configuration" do
    assert {:ok, %{tenant_id: "acme", default_ttl_s: 60}} =
             TenantConfig.lookup_by_tenant_id("acme")
  end

  test "lookup_by_api_key/1 returns the configuration of the key's tenant" do
    assert {:ok, %{tenant_id: "acme"}} = TenantConfig.lookup_by_api_key("key-acme")
  end

  test "an unknown tenant is not found" do
    assert {:error, :not_found} = TenantConfig.lookup_by_tenant_id("nope")
    assert {:error, :not_found} = TenantConfig.lookup_by_api_key("nope")
  end

  test "a lookup is served from the disk layer once the query cache is empty" do
    assert {:ok, _} = TenantConfig.lookup_by_tenant_id("acme")
    InMemory.clear()

    QueryCache.flush(
      TenantConfig.Cache.cache_name(),
      ReadThrough.namespace(TenantConfig.Cache.cache_name())
    )

    assert {:ok, %{tenant_id: "acme"}} = TenantConfig.lookup_by_tenant_id("acme")
  end

  test "invalidate/1 drops the tenant and its api key from every layer" do
    assert {:ok, _} = TenantConfig.lookup_by_api_key("key-acme")
    assert {:ok, _} = TenantConfig.lookup_by_tenant_id("acme")

    InMemory.clear()
    assert :ok = TenantConfig.invalidate("acme")

    assert {:error, :not_found} = TenantConfig.lookup_by_tenant_id("acme")
    assert {:error, :not_found} = TenantConfig.lookup_by_api_key("key-acme")
  end

  test "refresh/0 preloads every tenant configuration" do
    assert :ok = TenantConfig.refresh()
    InMemory.clear()

    assert {:ok, %{tenant_id: "acme"}} = TenantConfig.lookup_by_tenant_id("acme")
  end
end
