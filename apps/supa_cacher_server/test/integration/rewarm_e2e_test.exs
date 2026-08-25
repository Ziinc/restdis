defmodule SupaCacherServer.Integration.RewarmE2ETest do
  use ExUnit.Case

  @moduletag :integration

  alias Restdis.Cache.Key
  alias SupaCacherServer.Commands.Dispatcher
  alias SupaCacherServer.TenantStore.InMemory

  @tenant_id "rewarm-e2e-tenant"

  setup do
    Application.put_env(:supa_cacher_server, :postgrest_fetcher, SupaCacherServer.StubFetcher)

    {:ok, agent} = Agent.start(fn -> 0 end)
    Application.put_env(:supa_cacher_server, :stub_fetcher_agent, agent)
    Application.put_env(:supa_cacher_server, :stub_fetcher_body, [%{"e2e" => true}])

    InMemory.seed([
      %{
        api_key: "sk_e2e_rewarm",
        tenant_id: @tenant_id,
        default_ttl_s: 60,
        persist_cap: 50_000,
        pgrst_base_url: "http://localhost:3998",
        pgrst_api_key: "svc_key",
        replica_url: nil
      }
    ])

    Restdis.Cache.flush_tenant(@tenant_id)

    on_exit(fn ->
      Application.delete_env(:supa_cacher_server, :postgrest_fetcher)
      Application.delete_env(:supa_cacher_server, :stub_fetcher_agent)
      Application.delete_env(:supa_cacher_server, :stub_fetcher_body)
      SupaCacherServer.Rewarm.stop_tenant(@tenant_id)
      InMemory.clear()
      Restdis.Cache.flush_tenant(@tenant_id)
      Agent.stop(agent)
    end)

    state = %{authenticated?: true, tenant_id: @tenant_id, buffer: <<>>}
    {:ok, state: state, agent: agent}
  end

  test "REWARM 1: exactly one refetch fires within 1.2s after a cache hit", %{
    state: state,
    agent: agent
  } do
    {reply, _} = Dispatcher.dispatch(state, ["PGRST.QUERY", "/widgets?select=*"])

    wire_key =
      reply |> IO.iodata_to_binary() |> String.trim_leading("+") |> String.trim_trailing("\r\n")

    assert wire_key =~ "pgrst:"

    {_ok, _} = Dispatcher.dispatch(state, ["PGRST.POLICY", wire_key, "REWARM", "1"])

    {_cached, _} = Dispatcher.dispatch(state, ["PGRST.QUERY", "/widgets?select=*"])

    :timer.sleep(1200)

    assert Agent.get(agent, & &1) == 1
  end
end
