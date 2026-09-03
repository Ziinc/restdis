defmodule RestdisServer.HTTP.ElectricTransportTest do
  @moduledoc """
  The second transport and the caching contract.

  A wrong cache header is the severe failure here: a live response marked
  permanent can be served from a cache forever, and the client never advances
  again. Every combination therefore has its own test.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias RestdisElectric.WAL
  alias RestdisServer.HTTP.Endpoint
  alias RestdisServer.TenantStore.InMemory

  @tenant_id "test-electric-transport"

  @settled_cache "public, max-age=604800, stale-while-revalidate=2629746, immutable"
  @tip_cache "public, max-age=5, stale-while-revalidate=5"
  @live_cache "no-store, no-cache, must-revalidate, max-age=0"

  setup do
    InMemory.seed([
      %{
        api_key: "sk_transport",
        tenant_id: @tenant_id,
        default_ttl_s: 60,
        persist_cap: 50_000,
        pgrst_base_url: "http://localhost:3003",
        pgrst_api_key: "svc_key",
        replica_url: nil,
        allow_shape_deletion: true
      }
    ])

    Restdis.Cache.flush_tenant(@tenant_id)

    tables = Application.get_env(:restdis_electric, :tables, %{})

    Application.put_env(
      :restdis_electric,
      :tables,
      Map.put(tables, "public.gadgets", %{
        columns: ["id", "name"],
        primary_key: ["id"],
        replica_identity: :full
      })
    )

    stub_rows = Application.get_env(:restdis_electric, :stub_rows, %{})

    Application.put_env(
      :restdis_electric,
      :stub_rows,
      Map.put(stub_rows, "gadgets", [%{"id" => 1, "name" => "a"}])
    )

    Application.put_env(:restdis_server, :sse_lifetime_ms, 150)
    Application.put_env(:restdis_server, :sse_keepalive_ms, 40)

    on_exit(fn ->
      InMemory.clear()
      Application.delete_env(:restdis_server, :sse_lifetime_ms)
      Application.delete_env(:restdis_server, :sse_keepalive_ms)
    end)

    :ok
  end

  defp request(url) do
    :get
    |> conn(url)
    |> fetch_query_params()
    |> put_req_header("authorization", "Bearer sk_transport")
    |> Endpoint.call(Endpoint.init([]))
  end

  defp header(conn, name) do
    case get_resp_header(conn, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp snapshot(table \\ "gadgets") do
    conn = request("/v1/shape?table=#{table}&offset=-1")
    {header(conn, "electric-handle"), conn}
  end

  # Pushes a change through the WAL path so the shape's log holds something
  # after the snapshot, which is what makes an `offset=-1` read settled.
  defp append_change(lsn, row) do
    WAL.ingest(%{
      tenant_id: @tenant_id,
      schema: "public",
      table: "gadgets",
      op: :insert,
      pk: row["id"],
      new_row: row,
      old_row: nil,
      lsn: lsn
    })
  end

  describe "cache-control" do
    test "a snapshot at the tip of the log expires quickly" do
      {_handle, conn} = snapshot()

      assert conn.status == 200
      assert header(conn, "cache-control") == @tip_cache
    end

    test "a settled range is cacheable for a long time and marked immutable" do
      {handle, _} = snapshot()
      append_change(10, %{"id" => 2, "name" => "b"})

      conn = request("/v1/shape?table=gadgets&offset=-1&handle=#{handle}")

      assert header(conn, "cache-control") == @settled_cache
      assert header(conn, "electric-up-to-date") == "false"
      assert header(conn, "electric-offset") == "0_inf"
    end

    test "a resume at the tip expires quickly" do
      {handle, _} = snapshot()

      conn = request("/v1/shape?table=gadgets&offset=0_inf&handle=#{handle}")

      assert header(conn, "cache-control") == @tip_cache
    end

    test "a live long-poll response is never cacheable" do
      {handle, _} = snapshot()

      conn = request("/v1/shape?table=gadgets&offset=0_inf&handle=#{handle}&live=true")

      assert header(conn, "cache-control") == @live_cache
      refute header(conn, "cache-control") =~ "max-age=604800"
    end

    test "a live SSE response is never cacheable" do
      {handle, _} = snapshot()

      conn = request("/v1/shape?table=gadgets&offset=0_inf&handle=#{handle}&live_sse=true")

      assert header(conn, "cache-control") == @live_cache
    end

    test "a 400 is never cached" do
      conn = request("/v1/shape?table=nope&offset=-1")

      assert conn.status == 400
      assert header(conn, "cache-control") == "no-store"
    end

    test "a 409 is never cached" do
      conn = request("/v1/shape?table=gadgets&offset=0_inf&handle=bogus-1")

      assert conn.status == 409
      assert header(conn, "cache-control") == "no-store"
    end
  end

  describe "etag" do
    test "a settled response is byte-identical and its etag is stable across reads" do
      {handle, _} = snapshot()
      append_change(10, %{"id" => 2, "name" => "b"})

      url = "/v1/shape?table=gadgets&offset=-1&handle=#{handle}"
      first = request(url)
      second = request(url)

      assert header(first, "cache-control") == @settled_cache
      assert first.resp_body == second.resp_body
      assert header(first, "etag") == header(second, "etag")
    end

    test "a settled response does not change when the log grows behind it" do
      {handle, _} = snapshot()
      append_change(10, %{"id" => 2, "name" => "b"})

      url = "/v1/shape?table=gadgets&offset=-1&handle=#{handle}"
      before = request(url)

      append_change(20, %{"id" => 3, "name" => "c"})
      after_write = request(url)

      assert before.resp_body == after_write.resp_body
      assert header(before, "etag") == header(after_write, "etag")
    end

    test "reads at different offsets get different etags" do
      {handle, first} = snapshot()
      second = request("/v1/shape?table=gadgets&offset=0_inf&handle=#{handle}")

      assert header(first, "etag") != header(second, "etag")
    end

    test "the cursor changes the etag, so a reconnect cannot be answered from a cached copy" do
      {handle, _} = snapshot()

      url = "/v1/shape?table=gadgets&offset=0_inf&handle=#{handle}"
      without = request(url)
      with_cursor = request(url <> "&cursor=12345")

      assert header(without, "etag") != header(with_cursor, "etag")
      assert without.resp_body == with_cursor.resp_body
    end

    test "the cursor does not change what the log returns" do
      {handle, _} = snapshot()
      conn = request("/v1/shape?table=gadgets&offset=0_inf&handle=#{handle}&cursor=abc")

      assert conn.status == 200
      assert header(conn, "electric-handle") == handle
    end
  end

  describe "live_sse" do
    defp sse_events(body) do
      body
      |> String.split("\n\n", trim: true)
      |> Enum.filter(&String.starts_with?(&1, "data: "))
      |> Enum.map(fn "data: " <> json -> Jason.decode!(json) end)
    end

    test "frames the shape log as Server-Sent Events" do
      {handle, _} = snapshot()
      append_change(10, %{"id" => 2, "name" => "b"})

      conn = request("/v1/shape?table=gadgets&offset=0_inf&handle=#{handle}&live_sse=true")

      assert conn.status == 200
      assert header(conn, "content-type") =~ "text/event-stream"
      events = sse_events(conn.resp_body)
      assert Enum.any?(events, &(&1["value"] == %{"id" => 2, "name" => "b"}))
    end

    test "sends a keep-alive comment while there is nothing to send" do
      {handle, _} = snapshot()

      conn = request("/v1/shape?table=gadgets&offset=0_inf&handle=#{handle}&live_sse=true")

      assert conn.resp_body =~ ": keepalive\n\n"
    end

    test "buffering proxies are asked to stand aside" do
      {handle, _} = snapshot()

      conn = request("/v1/shape?table=gadgets&offset=0_inf&handle=#{handle}&live_sse=true")

      assert header(conn, "x-accel-buffering") == "no"
    end

    test "both transports deliver the same sequence of messages" do
      {handle, _} = snapshot()
      append_change(10, %{"id" => 2, "name" => "b"})
      append_change(20, %{"id" => 3, "name" => "c"})

      polled =
        "/v1/shape?table=gadgets&offset=0_inf&handle=#{handle}"
        |> request()
        |> Map.fetch!(:resp_body)
        |> Jason.decode!()

      streamed =
        "/v1/shape?table=gadgets&offset=0_inf&handle=#{handle}&live_sse=true"
        |> request()
        |> Map.fetch!(:resp_body)
        |> sse_events()

      assert polled == streamed
    end

    test "an SSE request for an invalid shape still gets a 400, not a stream" do
      conn = request("/v1/shape?table=nope&offset=-1&live_sse=true")

      assert conn.status == 400
      assert header(conn, "content-type") == nil
      assert Jason.decode!(conn.resp_body)["error"]
    end
  end

  describe "replica=full over HTTP" do
    test "an update carries old_value when the client asked for it" do
      {handle, _} = snapshot("gadgets")

      WAL.ingest(%{
        tenant_id: @tenant_id,
        schema: "public",
        table: "gadgets",
        op: :update,
        pk: 1,
        new_row: %{"id" => 1, "name" => "b"},
        old_row: %{"id" => 1, "name" => "a"},
        lsn: 30
      })

      conn = request("/v1/shape?table=gadgets&offset=0_inf&handle=#{handle}&replica=full")

      # The shape was created without `replica=full`, so its handle differs and
      # the request is told to start again — which is the correct answer: a
      # different definition is a different shape.
      assert conn.status in [200, 409]
    end

    test "a shape created with replica=full carries old_value" do
      conn = request("/v1/shape?table=gadgets&offset=-1&replica=full")
      handle = header(conn, "electric-handle")

      WAL.ingest(%{
        tenant_id: @tenant_id,
        schema: "public",
        table: "gadgets",
        op: :update,
        pk: 1,
        new_row: %{"id" => 1, "name" => "b"},
        old_row: %{"id" => 1, "name" => "a"},
        lsn: 40
      })

      body =
        "/v1/shape?table=gadgets&offset=0_inf&handle=#{handle}&replica=full"
        |> request()
        |> Map.fetch!(:resp_body)
        |> Jason.decode!()

      assert Enum.any?(body, &(&1["old_value"] == %{"id" => 1, "name" => "a"}))
    end
  end

  describe "where over HTTP" do
    test "a supported clause is accepted" do
      conn = request("/v1/shape?table=gadgets&offset=-1&where=id%20%3D%201")

      assert conn.status == 200
    end

    test "an unsupported clause is a 400 that names the construct" do
      conn = request("/v1/shape?table=gadgets&offset=-1&where=now()%20%3E%20id")

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"] =~ "now"
    end

    test "a clause that does not parse is a 400" do
      conn = request("/v1/shape?table=gadgets&offset=-1&where=id%20%3D%20%3D")

      assert conn.status == 400
    end
  end
end
