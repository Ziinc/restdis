defmodule RestdisServer.ClusterFallbackTest do
  use ExUnit.Case, async: false

  alias Restdis.Cache.Cluster
  alias Restdis.Cache.Key
  alias RestdisServer.Commands.Dispatcher
  alias RestdisServer.TenantStore.InMemory

  @ghost :"ghost@127.0.0.1"

  setup do
    tenant_id = remote_tenant()

    InMemory.seed([
      %{
        api_key: "sk_cluster",
        tenant_id: tenant_id,
        default_ttl_s: 60,
        persist_cap: 50_000,
        pgrst_base_url: "http://localhost:3001",
        pgrst_api_key: "svc_key",
        replica_url: nil
      }
    ])

    on_exit(fn ->
      send(Cluster.process_name(Restdis.Cache), {:nodedown, @ghost})
      Cluster.sync()
      InMemory.clear()
      Restdis.Cache.flush_tenant(tenant_id)
    end)

    {:ok,
     tenant_id: tenant_id, state: %{authenticated?: true, tenant_id: tenant_id, buffer: <<>>}}
  end

  test "PGRST.QUERY falls through to PostgREST when the owning node is unreachable", %{
    state: state,
    tenant_id: tenant_id
  } do
    body = [%{"id" => 7}]

    Req.Test.stub(RestdisServer.Finch, fn conn -> Req.Test.json(conn, body) end)

    assert Cluster.owner(tenant_id) == @ghost

    {reply, _state} = Dispatcher.dispatch(state, ["PGRST.QUERY", "/users?id=eq.7"])

    assert IO.iodata_to_binary(reply) =~ "pgrst:t:users:"
  end

  test "GET falls through to PostgREST when the owning node is unreachable", %{
    state: state,
    tenant_id: tenant_id
  } do
    body = [%{"id" => 7}]

    Req.Test.stub(RestdisServer.Finch, fn conn -> Req.Test.json(conn, body) end)

    assert Cluster.owner(tenant_id) == @ghost
    wire_key = Key.encode(Key.build(:table, "users", %{"id" => "eq.7"}))

    {elapsed_us, {reply, _state}} =
      :timer.tc(fn -> Dispatcher.dispatch(state, ["GET", wire_key]) end)

    assert IO.iodata_to_binary(reply) =~ ~s("id":7)
    assert elapsed_us <= 1_500_000
  end

  test "the HTTP endpoint marks a fallback response as a cache bypass", %{tenant_id: tenant_id} do
    body = [%{"id" => 7}]

    Req.Test.stub(RestdisServer.Finch, fn conn -> Req.Test.json(conn, body) end)

    assert Cluster.owner(tenant_id) == @ghost

    {:ok, resp} =
      Req.get(Req.new(plug: RestdisServer.HTTP.Endpoint),
        url: "/pgrst/query?path=/users",
        headers: [{"authorization", "Bearer sk_cluster"}],
        retry: false
      )

    assert resp.status == 200
    assert Req.Response.get_header(resp, "sc-cache") == ["BYPASS"]
    assert resp.body == body
  end

  test "GET surfaces a fallback fetch failure as an error", %{
    state: state,
    tenant_id: tenant_id
  } do
    Req.Test.stub(RestdisServer.Finch, fn conn -> Req.Test.transport_error(conn, :timeout) end)

    assert Cluster.owner(tenant_id) == @ghost
    wire_key = Key.encode(Key.build(:table, "users", %{"id" => "eq.7"}))

    {reply, _state} = Dispatcher.dispatch(state, ["GET", wire_key])

    assert IO.iodata_to_binary(reply) =~ "ERR origin unavailable"
  end

  test "the HTTP endpoint surfaces a fallback status error", %{tenant_id: tenant_id} do
    Req.Test.stub(RestdisServer.Finch, fn conn ->
      Plug.Conn.send_resp(conn, 404, Jason.encode!(%{message: "not found"}))
    end)

    assert Cluster.owner(tenant_id) == @ghost

    {:ok, resp} =
      Req.get(Req.new(plug: RestdisServer.HTTP.Endpoint),
        url: "/pgrst/query?path=/users",
        headers: [{"authorization", "Bearer sk_cluster"}],
        retry: false
      )

    assert resp.status == 404
    assert Jason.decode!(resp.body) == %{"error" => "upstream error"}
  end

  test "the HTTP endpoint surfaces an outright fallback fetch failure as a 502", %{
    tenant_id: tenant_id
  } do
    Req.Test.stub(RestdisServer.Finch, fn conn -> Req.Test.transport_error(conn, :timeout) end)

    assert Cluster.owner(tenant_id) == @ghost

    {:ok, resp} =
      Req.get(Req.new(plug: RestdisServer.HTTP.Endpoint),
        url: "/pgrst/query?path=/users",
        headers: [{"authorization", "Bearer sk_cluster"}],
        retry: false
      )

    assert resp.status == 502
    assert %{"error" => _} = Jason.decode!(resp.body)
  end

  defp remote_tenant do
    send(Cluster.process_name(Restdis.Cache), {:nodeup, @ghost})
    :ok = Cluster.sync()

    Enum.find_value(1..10_000, fn index ->
      tenant_id = "cluster_tenant_#{index}"
      if Cluster.owner(tenant_id) == @ghost, do: tenant_id
    end)
  end
end
