defmodule RestdisServer.Commands.PgrstQueryTest do
  use ExUnit.Case

  alias Restdis.Cache
  alias Restdis.Cache.Key
  alias RestdisServer.Commands.Dispatcher
  alias RestdisServer.PolicyStore
  alias RestdisServer.Rewarm
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

  test "PGRST.QUERY REWARM <seconds> is picked up by the tenant rewarm scheduler", %{
    state: state
  } do
    body = [%{"id" => 5, "name" => "Erin"}]

    Req.Test.stub(RestdisServer.Finch, fn conn ->
      Req.Test.json(conn, body)
    end)

    on_exit(fn -> Rewarm.stop_tenant(@tenant_id) end)

    {reply, _} = Dispatcher.dispatch(state, ["PGRST.QUERY", "/users?id=eq.5", "REWARM", "30"])
    wire_key = decode_wire_key(reply)

    {:ok, pid} = fetch_scheduler_pid(@tenant_id)
    table = :sys.get_state(pid).table

    assert [{^wire_key, entry}] = :ets.lookup(table, wire_key)
    assert entry.rewarm_s == 30
  end

  defp fetch_scheduler_pid(tenant_id) do
    case Registry.lookup(RestdisServer.Rewarm.Registry, tenant_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
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

    {:ok, key1} = Key.decode(key_str1)
    {:ok, key2} = Key.decode(key_str2)

    {:ok, value1} = Cache.peek(@tenant_id, key1)
    {:ok, value2} = Cache.peek(@tenant_id, key2)

    assert value1 == [%{"query" => "id=eq.1"}]
    assert value2 == [%{"query" => "id=eq.2"}]
  end

  test "PGRST.QUERY with no arguments replies with an error", %{state: state} do
    {reply, _} = Dispatcher.dispatch(state, ["PGRST.QUERY"])
    assert IO.iodata_to_binary(reply) =~ "wrong number of arguments"
  end

  test "PGRST.QUERY with an unparseable path replies with an error", %{state: state} do
    {reply, _} = Dispatcher.dispatch(state, ["PGRST.QUERY", "/"])
    assert IO.iodata_to_binary(reply) =~ "ERR"
  end

  test "PGRST.QUERY surfaces a non-2xx upstream status as an error", %{state: state} do
    Req.Test.stub(RestdisServer.Finch, fn conn ->
      Plug.Conn.send_resp(conn, 500, Jason.encode!(%{message: "boom"}))
    end)

    {reply, _} = Dispatcher.dispatch(state, ["PGRST.QUERY", "/broken_table"])
    assert IO.iodata_to_binary(reply) =~ "ERR PostgREST returned 500"
  end

  test "PGRST.QUERY surfaces an outright fetch failure as an error", %{state: state} do
    Req.Test.stub(RestdisServer.Finch, fn conn ->
      Req.Test.transport_error(conn, :timeout)
    end)

    {reply, _} = Dispatcher.dispatch(state, ["PGRST.QUERY", "/exploding_table"])
    assert IO.iodata_to_binary(reply) =~ "ERR fetch failed"
  end

  test "PGRST.QUERY ignores unrecognized trailing options", %{state: state} do
    body = [%{"id" => 6}]

    Req.Test.stub(RestdisServer.Finch, fn conn ->
      Req.Test.json(conn, body)
    end)

    {reply, _} = Dispatcher.dispatch(state, ["PGRST.QUERY", "/users?id=eq.6", "NOTANOPT", "1"])
    assert IO.iodata_to_binary(reply) =~ "pgrst:t:users:"
  end

  test "PGRST.QUERY ignores a trailing option with no value", %{state: state} do
    body = [%{"id" => 8}]

    Req.Test.stub(RestdisServer.Finch, fn conn ->
      Req.Test.json(conn, body)
    end)

    {reply, _} = Dispatcher.dispatch(state, ["PGRST.QUERY", "/users?id=eq.8", "TTL"])
    assert IO.iodata_to_binary(reply) =~ "pgrst:t:users:"
  end

  test "PGRST.QUERY refuses to cache past the tenant's persist_cap", %{} do
    tenant_id = "test-pgrst-tenant-persist-cap"

    InMemory.seed([
      %{
        api_key: "sk_pgrst_persist_cap",
        tenant_id: tenant_id,
        default_ttl_s: 60,
        persist_cap: 1,
        pgrst_base_url: "http://localhost:3001",
        pgrst_api_key: "svc_key",
        replica_url: nil
      }
    ])

    Restdis.Cache.flush_tenant(tenant_id)
    on_exit(fn -> InMemory.clear() end)

    state = %{authenticated?: true, tenant_id: tenant_id, buffer: <<>>}

    Req.Test.stub(RestdisServer.Finch, fn conn ->
      Req.Test.json(conn, [%{"ok" => true}])
    end)

    key1 = Key.build(:table, "widgets", %{"id" => "eq.1"})
    key2 = Key.build(:table, "widgets", %{"id" => "eq.2"})

    # Declaring PERSIST before the first fetch is enough to record the policy
    # even though the key isn't cached yet (`Restdis.Cache.set_persist`
    # returns `{:error, :not_found}`, which `PgrstPolicy` treats as a no-op).
    Dispatcher.dispatch(state, ["PGRST.POLICY", Key.encode(key1), "PERSIST"])
    Dispatcher.dispatch(state, ["PGRST.POLICY", Key.encode(key2), "PERSIST"])

    {reply1, _} = Dispatcher.dispatch(state, ["PGRST.QUERY", "/widgets?id=eq.1"])
    assert IO.iodata_to_binary(reply1) =~ "pgrst:t:widgets:"

    {reply2, _} = Dispatcher.dispatch(state, ["PGRST.QUERY", "/widgets?id=eq.2"])
    assert IO.iodata_to_binary(reply2) =~ "ERR persist cap reached"
  end

  test "PGRST.QUERY ignores a malformed TTL/REWARM numeric value", %{state: state} do
    body = [%{"id" => 7}]

    Req.Test.stub(RestdisServer.Finch, fn conn ->
      Req.Test.json(conn, body)
    end)

    {reply, _} =
      Dispatcher.dispatch(state, ["PGRST.QUERY", "/users?id=eq.7", "TTL", "notanumber"])

    assert IO.iodata_to_binary(reply) =~ "pgrst:t:users:"
  end
end
