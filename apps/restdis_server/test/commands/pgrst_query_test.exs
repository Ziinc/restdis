defmodule RestdisServer.Commands.PgrstQueryTest do
  use ExUnit.Case

  alias RestdisServer.Commands.Dispatcher
  alias RestdisServer.TenantStore.InMemory

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

  test "PGRST.QUERY forwards the query string to PostgREST", %{state: state} do
    Req.Test.stub(RestdisServer.Finch, fn conn ->
      assert conn.query_string == "id=eq.1"
      Req.Test.json(conn, [%{"id" => 1, "name" => "Alice"}])
    end)

    {reply, _} = Dispatcher.dispatch(state, ["PGRST.QUERY", "/users?id=eq.1"])
    wire = IO.iodata_to_binary(reply)
    assert wire =~ "pgrst:t:users:"
  end

  test "distinct query strings on the same table are cached and fetched separately", %{
    state: state
  } do
    Req.Test.stub(RestdisServer.Finch, fn conn ->
      Req.Test.json(conn, [%{"query" => conn.query_string}])
    end)

    {reply1, _} = Dispatcher.dispatch(state, ["PGRST.QUERY", "/users?id=eq.1"])
    {reply2, _} = Dispatcher.dispatch(state, ["PGRST.QUERY", "/users?id=eq.2"])

    wire1 = IO.iodata_to_binary(reply1)
    wire2 = IO.iodata_to_binary(reply2)

    refute wire1 == wire2

    [key_str1] = Regex.run(~r/pgrst:[^\r\n]+/, wire1)
    [key_str2] = Regex.run(~r/pgrst:[^\r\n]+/, wire2)

    {:ok, key1} = Restdis.Cache.Key.decode(key_str1)
    {:ok, key2} = Restdis.Cache.Key.decode(key_str2)

    {:ok, value1} = Restdis.Cache.peek(@tenant_id, key1)
    {:ok, value2} = Restdis.Cache.peek(@tenant_id, key2)

    assert value1 == [%{"query" => "id=eq.1"}]
    assert value2 == [%{"query" => "id=eq.2"}]
  end
end
