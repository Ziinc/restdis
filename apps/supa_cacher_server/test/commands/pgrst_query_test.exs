defmodule SupaCacherServer.Commands.PgrstQueryTest do
  use ExUnit.Case

  alias SupaCacherServer.Commands.Dispatcher
  alias SupaCacherServer.TenantStore.InMemory

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

    SupaCacherCache.flush_tenant(@tenant_id)
    on_exit(fn -> InMemory.clear() end)

    {:ok, state: %{authenticated?: true, tenant_id: @tenant_id, buffer: <<>>}}
  end

  test "PGRST.QUERY returns cached response on second call, origin called once", %{state: state} do
    body = [%{"id" => 1, "name" => "Alice"}]
    call_count = :counters.new(1, [])

    Req.Test.stub(SupaCacherServer.Finch, fn conn ->
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
end
