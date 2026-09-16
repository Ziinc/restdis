defmodule RestdisServer.TenantConfig.CacheTest do
  use ExUnit.Case, async: false

  alias RestdisServer.TenantConfig
  alias RestdisServer.TenantConfig.Cache
  alias RestdisServer.TenantStore.InMemory

  @tenant_id "tenant_cache_refresh_test"

  setup do
    InMemory.seed([
      %{
        api_key: "sk_cache_refresh",
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

  test "handling the periodic :refresh message reloads every tenant configuration" do
    pid = Process.whereis(Cache)
    assert is_pid(pid)

    send(pid, :refresh)
    # Ensure the message was processed before asserting on its effect.
    :sys.get_state(pid)

    InMemory.clear()
    assert {:ok, %{tenant_id: @tenant_id}} = TenantConfig.lookup_by_tenant_id(@tenant_id)
  end
end
