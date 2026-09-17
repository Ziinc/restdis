defmodule RestdisServer.Commands.PgrstPolicyTest do
  use ExUnit.Case

  alias Restdis.Cache.Key
  alias Restdis.Cache.TenantRegistry
  alias RestdisServer.Commands.Dispatcher
  alias RestdisServer.PolicyStore
  alias RestdisServer.Rewarm
  alias RestdisServer.TenantStore.InMemory

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

    Restdis.Cache.flush_tenant(@tenant_id)
    on_exit(fn -> InMemory.clear() end)

    key = Key.build(:table, "products", %{"id" => "eq.1"})
    Restdis.Cache.put(@tenant_id, key, [%{"id" => 1}], ttl_ms: 60_000)
    wire_key = Key.encode(key)

    {:ok,
     state: %{authenticated?: true, tenant_id: @tenant_id, buffer: <<>>},
     wire_key: wire_key,
     key: key}
  end

  test "PGRST.POLICY updates TTL observable via TTL command", %{state: state, wire_key: wire_key} do
    {reply, _} = Dispatcher.dispatch(state, ["PGRST.POLICY", wire_key, "TTL", "120"])
    assert IO.iodata_to_binary(reply) == "+OK\r\n"

    {ttl_reply, _} = Dispatcher.dispatch(state, ["TTL", wire_key])
    ttl_str = IO.iodata_to_binary(ttl_reply)
    {remaining, _} = Integer.parse(String.trim_leading(ttl_str, ":"))
    assert remaining > 100 and remaining <= 120
  end

  test "PGRST.POLICY stores rewarm and persist flags ephemerally", %{
    state: state,
    wire_key: wire_key
  } do
    {reply, _} = Dispatcher.dispatch(state, ["PGRST.POLICY", wire_key, "REWARM", "30", "PERSIST"])
    assert IO.iodata_to_binary(reply) == "+OK\r\n"

    policy = PolicyStore.get(@tenant_id, wire_key)
    assert policy.rewarm_s == 30
    assert policy.persist == true
  end

  test "PGRST.POLICY REWARM+PERSIST notifies the scheduler with the final merged policy", %{
    state: state,
    wire_key: wire_key
  } do
    on_exit(fn -> Rewarm.stop_tenant(@tenant_id) end)

    {reply, _} = Dispatcher.dispatch(state, ["PGRST.POLICY", wire_key, "REWARM", "30", "PERSIST"])
    assert IO.iodata_to_binary(reply) == "+OK\r\n"

    {:ok, pid} = fetch_scheduler_pid(@tenant_id)
    table = :sys.get_state(pid).table

    assert [{^wire_key, entry}] = :ets.lookup(table, wire_key)

    assert entry.rewarm_s == 30
    assert entry.persist == true
  end

  test "PGRST.POLICY PERSIST refuses past the tenant's persist cap", %{state: state} do
    # A fresh key, so `set_persist/4` actually runs instead of short-circuiting as a no-op.
    key = Key.build(:table, "products", %{"id" => "eq.2"})
    wire_key = Key.encode(key)
    Restdis.Cache.put(@tenant_id, key, [%{"id" => 2}], ttl_ms: 60_000)

    # Prime the same `:counters` ref so the next attempt tips over the cap, avoiding looping 50,000 times.
    ref = TenantRegistry.get_value(Restdis.Cache, @tenant_id, :qc_persist)
    :counters.add(ref, 1, 50_000)

    {reply, _} = Dispatcher.dispatch(state, ["PGRST.POLICY", wire_key, "PERSIST"])
    assert IO.iodata_to_binary(reply) == "-ERR persist cap reached\r\n"
  end

  defp fetch_scheduler_pid(tenant_id) do
    case Registry.lookup(RestdisServer.Rewarm.Registry, tenant_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  test "PGRST.POLICY with no arguments replies with an error", %{state: state} do
    {reply, _} = Dispatcher.dispatch(state, ["PGRST.POLICY"])
    assert IO.iodata_to_binary(reply) =~ "wrong number of arguments"
  end

  test "PGRST.POLICY with an undecodable key replies with an error", %{state: state} do
    {reply, _} = Dispatcher.dispatch(state, ["PGRST.POLICY", "bad:scheme:key"])
    assert IO.iodata_to_binary(reply) == "-ERR invalid cache key\r\n"
  end

  test "PGRST.POLICY TTL on a key with no cached value still succeeds", %{state: state} do
    key = Key.build(:table, "uncached_table", %{"id" => "eq.99"})
    wire_key = Key.encode(key)

    {reply, _} = Dispatcher.dispatch(state, ["PGRST.POLICY", wire_key, "TTL", "60"])
    assert IO.iodata_to_binary(reply) == "+OK\r\n"
  end

  test "PGRST.POLICY ignores an unrecognized trailing single option", %{
    state: state,
    wire_key: wire_key
  } do
    {reply, _} = Dispatcher.dispatch(state, ["PGRST.POLICY", wire_key, "NOTANOPT"])
    assert IO.iodata_to_binary(reply) == "+OK\r\n"
  end

  test "PGRST.POLICY ignores an unrecognized key/value pair option", %{
    state: state,
    wire_key: wire_key
  } do
    {reply, _} = Dispatcher.dispatch(state, ["PGRST.POLICY", wire_key, "NOTANOPT", "1"])
    assert IO.iodata_to_binary(reply) == "+OK\r\n"
  end
end
