defmodule RestdisServer.Commands.PersistTest do
  use ExUnit.Case, async: false

  import RestdisServer.TestUtils

  alias RestdisServer.Commands.Persist
  alias RestdisServer.Commands.Set
  alias RestdisServer.Commands.Ttl
  alias RestdisServer.TenantConfig
  alias RestdisServer.TenantStore.InMemory

  setup do
    tenant_id = "tenant_persist_#{System.unique_integer([:positive])}"

    InMemory.seed([
      %{
        tenant_id: tenant_id,
        api_key: "key-#{tenant_id}",
        default_ttl_s: 60,
        max_ttl_s: 3600,
        persist_cap: 10,
        pgrst_base_url: "http://localhost",
        pgrst_api_key: "pgrst",
        replica_url: nil
      }
    ])

    TenantConfig.invalidate(tenant_id)

    on_exit(fn ->
      Restdis.Cache.flush_tenant(tenant_id)
      InMemory.clear()
    end)

    {:ok, tenant_id: tenant_id}
  end

  test "PERSIST extends the TTL of an existing key to the tenant's max TTL", %{
    tenant_id: tenant_id
  } do
    Set.run(state(tenant_id), ["mykey", "hello", "EX", "10"])

    {reply, _state} = Persist.run(state(tenant_id), ["mykey"])
    assert IO.iodata_to_binary(reply) == ":1\r\n"

    {ttl_reply, _state} = Ttl.run(state(tenant_id), ["mykey"])

    assert IO.iodata_to_binary(ttl_reply) == ":3600\r\n" or
             IO.iodata_to_binary(ttl_reply) == ":3599\r\n"
  end

  test "PERSIST on a missing key replies 0", %{tenant_id: tenant_id} do
    {reply, _state} = Persist.run(state(tenant_id), ["mykey"])
    assert IO.iodata_to_binary(reply) == ":0\r\n"
  end

  test "PERSIST falls back to the default max TTL when the tenant has no config" do
    tenant_id = "tenant_persist_noconfig_#{System.unique_integer([:positive])}"
    Set.run(state(tenant_id), ["mykey", "hello", "EX", "10"])

    {reply, _state} = Persist.run(state(tenant_id), ["mykey"])
    assert IO.iodata_to_binary(reply) == ":1\r\n"

    Restdis.Cache.flush_tenant(tenant_id)
  end
end
