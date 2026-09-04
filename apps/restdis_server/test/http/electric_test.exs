defmodule RestdisServer.HTTP.ElectricTest do
  use ExUnit.Case

  alias RestdisElectric.Snapshotter.DirectPostgres
  alias RestdisServer.TenantStore.InMemory
  alias RestdisServer.Test.OpenApiConformance

  @tenant_id "test-electric-tenant"

  setup do
    InMemory.seed([
      %{
        api_key: "sk_electric",
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
      Map.put(tables, "public.widgets", %{
        columns: ["id", "name"],
        primary_key: ["id"],
        replica_identity: :full
      })
    )

    stub_rows = Application.get_env(:restdis_electric, :stub_rows, %{})

    Application.put_env(
      :restdis_electric,
      :stub_rows,
      Map.put(stub_rows, "widgets", [%{"id" => 1, "name" => "a"}])
    )

    on_exit(fn -> InMemory.clear() end)
    :ok
  end

  defp req do
    Req.new(plug: RestdisServer.HTTP.Endpoint)
  end

  defp auth, do: [{"authorization", "Bearer sk_electric"}]

  defp wait_until(check_fun, attempts \\ 50) do
    if check_fun.() do
      :ok
    else
      if attempts > 0 do
        Process.sleep(20)
        wait_until(check_fun, attempts - 1)
      else
        flunk("condition not met in time")
      end
    end
  end

  test "missing auth returns 401" do
    {:ok, resp} = Req.get(req(), url: "/v1/shape?table=widgets&offset=-1", retry: false)
    assert resp.status == 401
  end

  test "subscribing from -1 returns a snapshot with electric headers" do
    {:ok, resp} =
      Req.get(req(),
        url: "/v1/shape?table=widgets&offset=-1",
        headers: auth(),
        retry: false
      )

    assert resp.status == 200
    assert [handle] = Req.Response.get_header(resp, "electric-handle")
    assert Req.Response.get_header(resp, "electric-up-to-date") == ["true"]
    assert [_offset] = Req.Response.get_header(resp, "electric-offset")

    assert [schema_header] = Req.Response.get_header(resp, "electric-schema")
    assert {:ok, schema} = Jason.decode(schema_header)
    assert is_map(schema)
    assert Map.has_key?(schema, "id")
    assert Map.has_key?(schema, "name")
    assert %{"type" => _} = schema["id"]

    [insert_message, control_message] = resp.body
    assert insert_message["value"] == %{"id" => 1, "name" => "a"}
    assert insert_message["headers"]["operation"] == "insert"
    assert control_message["headers"]["control"] == "up-to-date"
    assert is_binary(handle)
  end

  test "a live=true response carries an electric-cursor header, which the real client library requires" do
    {:ok, snap} =
      Req.get(req(), url: "/v1/shape?table=widgets&offset=-1", headers: auth(), retry: false)

    [handle] = Req.Response.get_header(snap, "electric-handle")
    [offset] = Req.Response.get_header(snap, "electric-offset")

    :ok =
      RestdisElectric.WAL.ingest(%{
        tenant_id: @tenant_id,
        schema: "public",
        table: "widgets",
        op: :insert,
        pk: 2,
        new_row: %{"id" => 2, "name" => "b"},
        old_row: nil,
        lsn: 1
      })

    {:ok, resp} =
      Req.get(req(),
        url: "/v1/shape?table=widgets&offset=#{offset}&handle=#{handle}&live=true",
        headers: auth(),
        retry: false
      )

    assert resp.status == 200
    assert [_cursor] = Req.Response.get_header(resp, "electric-cursor")
  end

  test "subscribing at the tenant's max_shapes evicts the idle LRU shape, which then 409s on resume" do
    limits_tenant_id = "test-electric-tenant-shape-evict"

    InMemory.seed([
      %{
        api_key: "sk_electric_shape_evict",
        tenant_id: limits_tenant_id,
        default_ttl_s: 60,
        persist_cap: 50_000,
        pgrst_base_url: "http://localhost:3003",
        pgrst_api_key: "svc_key",
        replica_url: nil,
        allow_shape_deletion: true,
        max_shapes: 1
      }
    ])

    Application.put_env(
      :restdis_electric,
      :tables,
      Map.put(Application.get_env(:restdis_electric, :tables, %{}), "public.gadgets", %{
        columns: ["id"],
        primary_key: ["id"],
        replica_identity: :full
      })
    )

    Application.put_env(
      :restdis_electric,
      :stub_rows,
      Map.put(Application.get_env(:restdis_electric, :stub_rows, %{}), "gadgets", [%{"id" => 1}])
    )

    evict_auth = [{"authorization", "Bearer sk_electric_shape_evict"}]

    {:ok, first} =
      Req.get(req(), url: "/v1/shape?table=widgets&offset=-1", headers: evict_auth, retry: false)

    assert first.status == 200
    [first_handle] = Req.Response.get_header(first, "electric-handle")
    [first_offset] = Req.Response.get_header(first, "electric-offset")

    {:ok, second} =
      Req.get(req(), url: "/v1/shape?table=gadgets&offset=-1", headers: evict_auth, retry: false)

    assert second.status == 200

    {:ok, resumed} =
      Req.get(req(),
        url: "/v1/shape?table=widgets&offset=#{first_offset}&handle=#{first_handle}",
        headers: evict_auth,
        retry: false
      )

    assert resumed.status == 409
    assert [location] = Req.Response.get_header(resumed, "location")
    assert location =~ "offset=-1"
  end

  test "exceeding the tenant's max_shapes returns 429 when every existing shape is busy" do
    limits_tenant_id = "test-electric-tenant-shape-limit"

    InMemory.seed([
      %{
        api_key: "sk_electric_shape_limit",
        tenant_id: limits_tenant_id,
        default_ttl_s: 60,
        persist_cap: 50_000,
        pgrst_base_url: "http://localhost:3003",
        pgrst_api_key: "svc_key",
        replica_url: nil,
        allow_shape_deletion: true,
        max_shapes: 1
      },
      %{
        api_key: "sk_electric",
        tenant_id: @tenant_id,
        default_ttl_s: 60,
        persist_cap: 50_000,
        pgrst_base_url: "http://localhost:3003",
        pgrst_api_key: "svc_key",
        replica_url: nil,
        allow_shape_deletion: true
      }
    ])

    Application.put_env(
      :restdis_electric,
      :tables,
      Map.put(Application.get_env(:restdis_electric, :tables, %{}), "public.gadgets", %{
        columns: ["id"],
        primary_key: ["id"],
        replica_identity: :full
      })
    )

    limits_auth = [{"authorization", "Bearer sk_electric_shape_limit"}]

    {:ok, first} =
      Req.get(req(),
        url: "/v1/shape?table=widgets&offset=-1",
        headers: limits_auth,
        retry: false
      )

    assert first.status == 200
    [handle] = Req.Response.get_header(first, "electric-handle")
    [offset] = Req.Response.get_header(first, "electric-offset")

    parent = self()

    spawn(fn ->
      result =
        Req.get(req(),
          url: "/v1/shape?table=widgets&offset=#{offset}&handle=#{handle}&live=true",
          headers: limits_auth,
          retry: false
        )

      send(parent, {:live_poll, result})
    end)

    wait_until(fn -> RestdisElectric.Log.waiting?(limits_tenant_id, handle) end)

    {:ok, resp} =
      Req.get(req(), url: "/v1/shape?table=gadgets&offset=-1", headers: limits_auth, retry: false)

    assert resp.status == 429
    assert Jason.decode!(resp.body)["error"] =~ "limit of 1 active shape"

    :ok =
      RestdisElectric.WAL.ingest(%{
        tenant_id: limits_tenant_id,
        schema: "public",
        table: "widgets",
        op: :insert,
        pk: 2,
        new_row: %{"id" => 2, "name" => "b"},
        old_row: nil,
        lsn: 1
      })

    assert_receive {:live_poll, {:ok, %{status: 200}}}, 5_000
  end

  test "exceeding the tenant's max_waiting_clients on a live long-poll returns 429" do
    limits_tenant_id = "test-electric-tenant-wait-limit"

    InMemory.seed([
      %{
        api_key: "sk_electric_wait_limit",
        tenant_id: limits_tenant_id,
        default_ttl_s: 60,
        persist_cap: 50_000,
        pgrst_base_url: "http://localhost:3003",
        pgrst_api_key: "svc_key",
        replica_url: nil,
        allow_shape_deletion: true,
        max_waiting_clients: 0
      },
      %{
        api_key: "sk_electric",
        tenant_id: @tenant_id,
        default_ttl_s: 60,
        persist_cap: 50_000,
        pgrst_base_url: "http://localhost:3003",
        pgrst_api_key: "svc_key",
        replica_url: nil,
        allow_shape_deletion: true
      }
    ])

    limits_auth = [{"authorization", "Bearer sk_electric_wait_limit"}]

    {:ok, snap} =
      Req.get(req(),
        url: "/v1/shape?table=widgets&offset=-1",
        headers: limits_auth,
        retry: false
      )

    [handle] = Req.Response.get_header(snap, "electric-handle")
    [offset] = Req.Response.get_header(snap, "electric-offset")

    {:ok, resp} =
      Req.get(req(),
        url: "/v1/shape?table=widgets&offset=#{offset}&handle=#{handle}&live=true",
        headers: limits_auth,
        retry: false
      )

    assert resp.status == 429
    assert Jason.decode!(resp.body)["error"] =~ "limit of 0 clients waiting"
  end

  test "an unknown table returns 400" do
    {:ok, resp} =
      Req.get(req(), url: "/v1/shape?table=nope&offset=-1", headers: auth(), retry: false)

    assert resp.status == 400
  end

  test "log=changes_only returns 400 when the tenant has no direct Postgres pool" do
    {:ok, resp} =
      Req.get(req(),
        url: "/v1/shape?table=widgets&offset=-1&log=changes_only",
        headers: auth(),
        retry: false
      )

    assert resp.status == 400
  end

  describe "log=changes_only with a direct Postgres pool" do
    @direct_tenant_id "test-electric-tenant-direct"
    @direct_pg_url "postgres://postgres:postgres@#{System.get_env("POSTGRES_HOSTNAME", "localhost")}:5432/restdis_test"

    setup do
      {:ok, conn} =
        Postgrex.start_link(DirectPostgres.connect_opts(@direct_pg_url))

      Postgrex.query!(conn, "DROP TABLE IF EXISTS http_changes_only_widgets", [])

      Postgrex.query!(
        conn,
        "CREATE TABLE http_changes_only_widgets (id integer PRIMARY KEY, name text)",
        []
      )

      Postgrex.query!(
        conn,
        "INSERT INTO http_changes_only_widgets (id, name) VALUES (1, 'a')",
        []
      )

      on_exit(fn ->
        {:ok, conn} =
          Postgrex.start_link(DirectPostgres.connect_opts(@direct_pg_url))

        Postgrex.query!(conn, "DROP TABLE IF EXISTS http_changes_only_widgets", [])
      end)

      Application.put_env(
        :restdis_electric,
        :tables,
        Map.put(
          Application.get_env(:restdis_electric, :tables, %{}),
          "public.http_changes_only_widgets",
          %{
            columns: ["id", "name"],
            primary_key: ["id"],
            replica_identity: :full
          }
        )
      )

      InMemory.seed([
        %{
          api_key: "sk_electric_direct",
          tenant_id: @direct_tenant_id,
          default_ttl_s: 60,
          persist_cap: 50_000,
          pgrst_base_url: "http://localhost:3003",
          pgrst_api_key: "svc_key",
          replica_url: nil,
          allow_shape_deletion: true,
          direct_pg_url: @direct_pg_url
        }
      ])

      Restdis.Cache.flush_tenant(@direct_tenant_id)

      :ok
    end

    test "returns a snapshot-end message with the descriptor, and no row inserts" do
      {:ok, resp} =
        Req.get(req(),
          url: "/v1/shape?table=http_changes_only_widgets&offset=-1&log=changes_only",
          headers: [{"authorization", "Bearer sk_electric_direct"}],
          retry: false
        )

      assert resp.status == 200

      assert [
               %{"headers" => %{"control" => "snapshot-end", "snapshot" => snapshot_text}},
               %{"headers" => %{"control" => "up-to-date"}}
             ] = resp.body

      assert is_binary(snapshot_text)

      assert {:ok, %{xmin: _, xmax: _, xip_list: _}} =
               RestdisElectric.SnapshotDescriptor.parse(snapshot_text)
    end
  end

  test "resuming with an unknown handle returns 409 with a location header" do
    {:ok, resp} =
      Req.get(req(),
        url: "/v1/shape?table=widgets&offset=0_inf&handle=bogus-1",
        headers: auth(),
        retry: false
      )

    assert resp.status == 409
    assert [location] = Req.Response.get_header(resp, "location")
    assert location =~ "offset=-1"
  end

  test "resuming without a handle returns 400" do
    {:ok, resp} =
      Req.get(req(),
        url: "/v1/shape?table=widgets&offset=0_inf",
        headers: auth(),
        retry: false
      )

    assert resp.status == 400
  end

  describe "the secret query parameter" do
    setup do
      InMemory.seed([
        %{
          api_key: "sk_secret",
          tenant_id: "secret-tenant",
          default_ttl_s: 60,
          persist_cap: 50_000,
          pgrst_base_url: "http://localhost:3003",
          pgrst_api_key: "svc_key",
          replica_url: nil,
          allow_shape_deletion: false,
          shape_secret: "sekrit"
        }
      ])

      Restdis.Cache.flush_tenant("secret-tenant")
      :ok
    end

    defp secret_auth, do: [{"authorization", "Bearer sk_secret"}]

    test "a missing secret returns 401" do
      {:ok, resp} =
        Req.get(req(),
          url: "/v1/shape?table=widgets&offset=-1",
          headers: secret_auth(),
          retry: false
        )

      assert resp.status == 401
    end

    test "a wrong secret returns 401" do
      {:ok, resp} =
        Req.get(req(),
          url: "/v1/shape?table=widgets&offset=-1&secret=wrong",
          headers: secret_auth(),
          retry: false
        )

      assert resp.status == 401
    end

    test "the matching secret succeeds" do
      {:ok, resp} =
        Req.get(req(),
          url: "/v1/shape?table=widgets&offset=-1&secret=sekrit",
          headers: secret_auth(),
          retry: false
        )

      assert resp.status == 200
    end
  end

  describe "gatekeeper mode" do
    setup do
      InMemory.seed([
        %{
          api_key: "sk_gatekeeper",
          tenant_id: "gatekeeper-tenant",
          default_ttl_s: 60,
          persist_cap: 50_000,
          pgrst_base_url: "http://localhost:3003",
          pgrst_api_key: "svc_key",
          replica_url: nil,
          allow_shape_deletion: false,
          auth_mode: "gatekeeper",
          shapes: %{"widget-feed" => %{table: "widgets"}}
        }
      ])

      Restdis.Cache.flush_tenant("gatekeeper-tenant")
      :ok
    end

    defp gatekeeper_auth, do: [{"authorization", "Bearer sk_gatekeeper"}]

    test "subscribing by shape name succeeds" do
      {:ok, resp} =
        Req.get(req(),
          url: "/v1/shape?shape=widget-feed&offset=-1",
          headers: gatekeeper_auth(),
          retry: false
        )

      assert resp.status == 200
    end

    test "sending 'table' returns 400" do
      {:ok, resp} =
        Req.get(req(),
          url: "/v1/shape?shape=widget-feed&table=widgets&offset=-1",
          headers: gatekeeper_auth(),
          retry: false
        )

      assert resp.status == 400
    end

    test "an unknown shape name returns 400" do
      {:ok, resp} =
        Req.get(req(),
          url: "/v1/shape?shape=nope&offset=-1",
          headers: gatekeeper_auth(),
          retry: false
        )

      assert resp.status == 400
    end

    test "a missing shape name returns 400" do
      {:ok, resp} =
        Req.get(req(),
          url: "/v1/shape?offset=-1",
          headers: gatekeeper_auth(),
          retry: false
        )

      assert resp.status == 400
    end
  end

  describe "DELETE /v1/shape conformance" do
    test "removes the shape when allow_shape_deletion is set" do
      {:ok, snapshot} =
        Req.get(req(),
          url: "/v1/shape?table=widgets&offset=-1",
          headers: auth(),
          retry: false
        )

      [handle] = Req.Response.get_header(snapshot, "electric-handle")

      {:ok, resp} =
        Req.delete(req(),
          url: "/v1/shape?handle=#{handle}",
          headers: auth(),
          retry: false
        )

      assert resp.status == 202
      assert Jason.decode!(resp.body) == %{"ok" => true}
      OpenApiConformance.assert_conforms!("delete", "/v1/shape", resp)

      {:ok, resumed} =
        Req.get(req(),
          url: "/v1/shape?table=widgets&offset=0_inf&handle=#{handle}",
          headers: auth(),
          retry: false
        )

      assert resumed.status == 409
      OpenApiConformance.assert_conforms!("get", "/v1/shape", resumed)
    end

    test "returns 404 when disabled for the tenant" do
      InMemory.seed([
        %{
          api_key: "sk_no_delete",
          tenant_id: "no-delete-tenant",
          default_ttl_s: 60,
          persist_cap: 50_000,
          pgrst_base_url: "http://localhost:3003",
          pgrst_api_key: "svc_key",
          replica_url: nil,
          allow_shape_deletion: false
        }
      ])

      {:ok, resp} =
        Req.delete(req(),
          url: "/v1/shape?handle=whatever",
          headers: [{"authorization", "Bearer sk_no_delete"}],
          retry: false
        )

      assert resp.status == 404
      assert %{"error" => _} = Jason.decode!(resp.body)
      OpenApiConformance.assert_conforms!("delete", "/v1/shape", resp)
    end

    test "returns 400 when the 'handle' query parameter is missing" do
      {:ok, resp} =
        Req.delete(req(),
          url: "/v1/shape",
          headers: auth(),
          retry: false
        )

      assert resp.status == 400
      assert %{"error" => _} = Jason.decode!(resp.body)
      OpenApiConformance.assert_conforms!("delete", "/v1/shape", resp)
    end

    test "returns 400 when the 'handle' query parameter is empty" do
      {:ok, resp} =
        Req.delete(req(),
          url: "/v1/shape?handle=",
          headers: auth(),
          retry: false
        )

      assert resp.status == 400
      OpenApiConformance.assert_conforms!("delete", "/v1/shape", resp)
    end

    test "returns 401 when the API key is missing" do
      {:ok, resp} =
        Req.delete(req(),
          url: "/v1/shape?handle=whatever",
          retry: false
        )

      assert resp.status == 401
      assert %{"error" => _} = Jason.decode!(resp.body)
      OpenApiConformance.assert_conforms!("delete", "/v1/shape", resp)
    end

    test "returns 401 when the API key is invalid" do
      {:ok, resp} =
        Req.delete(req(),
          url: "/v1/shape?handle=whatever",
          headers: [{"authorization", "Bearer nope"}],
          retry: false
        )

      assert resp.status == 401
      OpenApiConformance.assert_conforms!("delete", "/v1/shape", resp)
    end

    test "deleting an unknown handle still returns 202" do
      {:ok, resp} =
        Req.delete(req(),
          url: "/v1/shape?handle=does-not-exist",
          headers: auth(),
          retry: false
        )

      assert resp.status == 202
      OpenApiConformance.assert_conforms!("delete", "/v1/shape", resp)
    end
  end
end
