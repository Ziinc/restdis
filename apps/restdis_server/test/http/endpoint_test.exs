defmodule RestdisServer.HTTP.EndpointTest do
  use ExUnit.Case

  alias Restdis.Cache.Key
  alias RestdisServer.HTTP.Endpoint
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

  test "unknown route returns 404" do
    {:ok, resp} = Req.get(req(), url: "/nope", retry: false)
    assert resp.status == 404
    assert Jason.decode!(resp.body) == %{"error" => "not found"}
  end

  test "/pgrst/query without a path query param returns 400" do
    {:ok, resp} =
      Req.get(req(),
        url: "/pgrst/query",
        headers: [{"authorization", "Bearer sk_http"}],
        retry: false
      )

    assert resp.status == 400
    assert Jason.decode!(resp.body) == %{"error" => "missing 'path' query parameter"}
  end

  test "/pgrst/query with an empty path the parser rejects returns 400" do
    {:ok, resp} =
      Req.get(req(),
        url: "/pgrst/query?path=/",
        headers: [{"authorization", "Bearer sk_http"}],
        retry: false
      )

    assert resp.status == 400
    assert %{"error" => _} = Jason.decode!(resp.body)
  end

  test "/pgrst/query surfaces a non-2xx upstream status verbatim" do
    Req.Test.stub(RestdisServer.Finch, fn conn ->
      Plug.Conn.send_resp(conn, 404, Jason.encode!(%{message: "not found"}))
    end)

    {:ok, resp} =
      Req.get(req(),
        url: "/pgrst/query?path=/missing_table",
        headers: [{"authorization", "Bearer sk_http"}],
        retry: false
      )

    assert resp.status == 404
    assert Jason.decode!(resp.body) == %{"error" => "upstream error"}
  end

  test "/pgrst/query returns 502 when the upstream fetch fails outright" do
    Req.Test.stub(RestdisServer.Finch, fn conn ->
      Req.Test.transport_error(conn, :timeout)
    end)

    {:ok, resp} =
      Req.get(req(),
        url: "/pgrst/query?path=/exploding_table",
        headers: [{"authorization", "Bearer sk_http"}],
        retry: false
      )

    assert resp.status == 502
    assert %{"error" => _} = Jason.decode!(resp.body)
  end

  test "/pgrst/policy without auth returns 401" do
    {:ok, resp} =
      Req.post(req(),
        url: "/pgrst/policy",
        json: %{"key" => "somekey"},
        retry: false
      )

    assert resp.status == 401
  end

  test "/pgrst/policy with an invalid JSON body returns 400" do
    conn =
      :post
      |> Plug.Test.conn("/pgrst/policy", "{not json")
      |> Plug.Conn.put_req_header("authorization", "Bearer sk_http")
      |> Plug.Conn.put_req_header("content-type", "application/octet-stream")

    resp = Endpoint.call(conn, [])

    assert resp.status == 400
    assert Jason.decode!(resp.resp_body) == %{"error" => "invalid JSON"}
  end

  test "/pgrst/policy without a 'key' returns 400" do
    {:ok, resp} =
      Req.post(req(),
        url: "/pgrst/policy",
        headers: [{"authorization", "Bearer sk_http"}],
        json: %{},
        retry: false
      )

    assert resp.status == 400
    assert Jason.decode!(resp.body) == %{"error" => "invalid or missing 'key'"}
  end

  test "/pgrst/policy with an undecodable key returns 400" do
    {:ok, resp} =
      Req.post(req(),
        url: "/pgrst/policy",
        headers: [{"authorization", "Bearer sk_http"}],
        json: %{"key" => "bad:scheme:key"},
        retry: false
      )

    assert resp.status == 400
    assert Jason.decode!(resp.body) == %{"error" => "invalid or missing 'key'"}
  end

  test "/pgrst/policy sets rewarm, persist and ttl, acknowledged with ok" do
    key = Key.build(:table, "policytable", %{"id" => "eq.1"})
    wire_key = Key.encode(key)
    Restdis.Cache.put(@tenant_id, key, [%{"id" => 1}], ttl_ms: 60_000)

    {:ok, resp} =
      Req.post(req(),
        url: "/pgrst/policy",
        headers: [{"authorization", "Bearer sk_http"}],
        json: %{"key" => wire_key, "rewarm" => 30, "persist" => true, "ttl_s" => 120},
        retry: false
      )

    assert resp.status == 200
    assert Jason.decode!(resp.body) == %{"ok" => true}
    assert Req.Response.get_header(resp, "sc-cache-rewarm") == ["deferred"]
  end

  test "/pgrst/policy with a ttl but no cached value still acknowledges" do
    key = Key.build(:table, "neverpersisted", %{"id" => "eq.9"})
    wire_key = Key.encode(key)

    {:ok, resp} =
      Req.post(req(),
        url: "/pgrst/policy",
        headers: [{"authorization", "Bearer sk_http"}],
        json: %{"key" => wire_key, "ttl_s" => 30},
        retry: false
      )

    assert resp.status == 200
    assert Jason.decode!(resp.body) == %{"ok" => true}
  end

  # `Req.new(plug: ...)` fetches query params before invoking the plug (every other test here relies on that); this test builds the conn the way Bandit actually delivers it, unfetched, to catch a regression the rest of this file is blind to.
  test "query params are read from a conn the way Bandit delivers it, unfetched" do
    conn =
      :get
      |> Plug.Test.conn("/pgrst/query?path=/users")
      |> Plug.Conn.put_req_header("authorization", "Bearer sk_http")

    Req.Test.stub(RestdisServer.Finch, fn conn ->
      Req.Test.json(conn, [%{"id" => 1}])
    end)

    resp = Endpoint.call(conn, [])

    assert resp.status == 200
  end
end
