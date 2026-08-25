defmodule RestdisServer.HTTP.EndpointTest do
  use ExUnit.Case

  alias RestdisServer.TenantStore.InMemory

  @tenant_id "test-http-tenant"

  setup do
    InMemory.seed([
      %{
        api_key: "sk_http",
        tenant_id: @tenant_id,
        default_ttl_s: 60,
        persist_cap: 50_000,
        pgrst_base_url: "http://localhost:3003",
        pgrst_api_key: "svc_key",
        replica_url: nil
      }
    ])

    Restdis.Cache.flush_tenant(@tenant_id)
    on_exit(fn -> InMemory.clear() end)
    :ok
  end

  defp req do
    Req.new(plug: RestdisServer.HTTP.Endpoint)
  end

  test "missing auth returns 401" do
    {:ok, resp} = Req.get(req(), url: "/pgrst/query?path=/users", retry: false)
    assert resp.status == 401
  end

  test "invalid auth returns 401" do
    {:ok, resp} =
      Req.get(req(),
        url: "/pgrst/query?path=/users",
        headers: [{"authorization", "Bearer bad_key"}],
        retry: false
      )

    assert resp.status == 401
  end

  test "valid auth returns 200 with SC-Cache headers on miss" do
    body = [%{"id" => 1}]

    Req.Test.stub(RestdisServer.Finch, fn conn ->
      Req.Test.json(conn, body)
    end)

    {:ok, resp} =
      Req.get(req(),
        url: "/pgrst/query?path=/products2",
        headers: [{"authorization", "Bearer sk_http"}],
        retry: false
      )

    assert resp.status == 200
    assert Req.Response.get_header(resp, "sc-cache") == ["MISS"]
    assert Req.Response.get_header(resp, "sc-cache-ttl") != []
  end

  test "second request returns SC-Cache: HIT" do
    body = [%{"id" => 2}]

    Req.Test.stub(RestdisServer.Finch, fn conn ->
      Req.Test.json(conn, body)
    end)

    auth = [{"authorization", "Bearer sk_http"}]

    Req.get(req(), url: "/pgrst/query?path=/orders2", headers: auth, retry: false)

    {:ok, resp2} =
      Req.get(req(), url: "/pgrst/query?path=/orders2", headers: auth, retry: false)

    assert Req.Response.get_header(resp2, "sc-cache") == ["HIT"]
  end

  test "/health returns 200" do
    {:ok, resp} = Req.get(req(), url: "/health", retry: false)
    assert resp.status == 200
  end

  test "/metrics returns 200 with Prometheus text exposition" do
    {:ok, resp} = Req.get(req(), url: "/metrics", retry: false)

    assert resp.status == 200
    assert [content_type] = Req.Response.get_header(resp, "content-type")
    assert content_type =~ "text/plain"
  end

  test "/metrics reflects telemetry events emitted by the application" do
    :telemetry.execute(
      [:restdis_server, :rewarm, :cold_read],
      %{count: 1},
      %{tenant_id: @tenant_id}
    )

    {:ok, resp} = Req.get(req(), url: "/metrics", retry: false)

    assert resp.status == 200
    assert resp.body =~ "restdis_server_rewarm_cold_read_count"
    assert resp.body =~ ~s(tenant_id="#{@tenant_id}")
  end
end
