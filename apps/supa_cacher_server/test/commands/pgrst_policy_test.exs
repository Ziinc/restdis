defmodule SupaCacherServer.Commands.PgrstPolicyTest do
  use ExUnit.Case

  alias SupaCacherCache.Key
  alias SupaCacherServer.Commands.Dispatcher
  alias SupaCacherServer.PolicyStore
  alias SupaCacherServer.TenantStore.InMemory

  @tenant_id "test-policy-tenant"

  setup do
    InMemory.seed([
      %{
        api_key: "sk_policy",
        tenant_id: @tenant_id,
        default_ttl_s: 60,
        persist_cap: 50_000,
        pgrst_base_url: "http://localhost:3002",
        pgrst_api_key: "svc_key",
        replica_url: nil
      }
    ])

    SupaCacherCache.flush_tenant(@tenant_id)
    on_exit(fn -> InMemory.clear() end)

    key = Key.build(:table, "products", %{"id" => "eq.1"})
    SupaCacherCache.put(@tenant_id, key, [%{"id" => 1}], ttl_ms: 60_000)
    wire_key = Key.encode(key)

    {:ok, state: %{authenticated?: true, tenant_id: @tenant_id, buffer: <<>>}, wire_key: wire_key, key: key}
  end

  test "PGRST.POLICY updates TTL observable via TTL command", %{state: state, wire_key: wire_key} do
    {reply, _} = Dispatcher.dispatch(state, ["PGRST.POLICY", wire_key, "TTL", "120"])
    assert IO.iodata_to_binary(reply) == "+OK\r\n"

    {ttl_reply, _} = Dispatcher.dispatch(state, ["TTL", wire_key])
    ttl_str = IO.iodata_to_binary(ttl_reply)
    {remaining, _} = Integer.parse(String.trim_leading(ttl_str, ":"))
    assert remaining > 100 and remaining <= 120
  end

  test "PGRST.POLICY stores rewarm and persist flags ephemerally", %{state: state, wire_key: wire_key} do
    {reply, _} = Dispatcher.dispatch(state, ["PGRST.POLICY", wire_key, "REWARM", "30", "PERSIST"])
    assert IO.iodata_to_binary(reply) == "+OK\r\n"

    policy = PolicyStore.get(@tenant_id, wire_key)
    assert policy.rewarm_s == 30
    assert policy.persist == true
  end
end
