defmodule RestdisServer.Commands.PgrstQueryTest do
  use ExUnit.Case

  alias RestdisServer.Commands.Dispatcher
  alias RestdisServer.PolicyStore
  alias RestdisServer.TenantStore.InMemory

  defp decode_wire_key(reply) do
    reply
    |> IO.iodata_to_binary()
    |> String.trim_leading("$")
    |> String.split("\r\n", parts: 2)
    |> List.last()
    |> String.trim_trailing("\r\n")
  end

  @tenant_id "test-pgrst-tenant"

  setup do
    InMemory.seed([
      %{
        api_key: "sk_pgrst",
        tenant_id: @tenant_id,
        default_ttl_s: 60,
        persist_cap: 50_000,
        pgrst_base_url: "http://localhost:3001",
        pgrst_api_key: "svc_key",
        replica_url: nil
      }
    ])

    Restdis.Cache.flush_tenant(@tenant_id)
    on_exit(fn -> InMemory.clear() end)

    {:ok, state: %{authenticated?: true, tenant_id: @tenant_id, buffer: <<>>}}
  end

  test "PGRST.QUERY returns cached response on second call, origin called once", %{state: state} do
    body = [%{"id" => 1, "name" => "Alice"}]
    call_count = :counters.new(1, [])

    Req.Test.stub(RestdisServer.Finch, fn conn ->
      :counters.add(call_count, 1, 1)
      Req.Test.json(conn, body)
    end)

    {reply1, _} = Dispatcher.dispatch(state, ["PGRST.QUERY", "/users?id=eq.1"])
    wire = IO.iodata_to_binary(reply1)
    assert wire =~ "pgrst:t:users:"
    assert :counters.get(call_count, 1) == 1

    {_reply2, _} = Dispatcher.dispatch(state, ["PGRST.QUERY", "/users?id=eq.1"])
    assert :counters.get(call_count, 1) == 1
  end

  test "PGRST.QUERY without REWARM leaves rewarm policy unset", %{state: state} do
    body = [%{"id" => 2, "name" => "Bob"}]

    Req.Test.stub(RestdisServer.Finch, fn conn ->
      Req.Test.json(conn, body)
    end)

    {reply, _} = Dispatcher.dispatch(state, ["PGRST.QUERY", "/users?id=eq.2"])
    wire_key = decode_wire_key(reply)

    policy = PolicyStore.get(@tenant_id, wire_key)
    assert policy.rewarm_s == nil
  end

  test "PGRST.QUERY REWARM <seconds> registers the same rewarm policy as PGRST.POLICY", %{
    state: state
  } do
    body = [%{"id" => 3, "name" => "Carol"}]

    Req.Test.stub(RestdisServer.Finch, fn conn ->
      Req.Test.json(conn, body)
    end)

    {reply, _} = Dispatcher.dispatch(state, ["PGRST.QUERY", "/users?id=eq.3", "REWARM", "30"])
    wire_key = decode_wire_key(reply)

    policy = PolicyStore.get(@tenant_id, wire_key)
    assert policy.rewarm_s == 30
  end

  test "PGRST.QUERY TTL <seconds> REWARM <seconds> applies both options together", %{
    state: state
  } do
    body = [%{"id" => 4, "name" => "Dave"}]

    Req.Test.stub(RestdisServer.Finch, fn conn ->
      Req.Test.json(conn, body)
    end)

    {reply, _} =
      Dispatcher.dispatch(state, [
        "PGRST.QUERY",
        "/users?id=eq.4",
        "TTL",
        "120",
        "REWARM",
        "45"
      ])

    wire_key = decode_wire_key(reply)

    policy = PolicyStore.get(@tenant_id, wire_key)
    assert policy.rewarm_s == 45

    {ttl_reply, _} = Dispatcher.dispatch(state, ["TTL", wire_key])
    ttl_str = IO.iodata_to_binary(ttl_reply)
    {remaining, _} = Integer.parse(String.trim_leading(ttl_str, ":"))
    assert remaining > 100 and remaining <= 120
  end
end
