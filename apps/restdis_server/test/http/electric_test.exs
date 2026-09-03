defmodule RestdisServer.HTTP.ElectricTest do
  use ExUnit.Case

  alias RestdisElectric.Snapshotter.DirectPostgres
  alias RestdisServer.TenantStore.InMemory

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

  test "exceeding the tenant's max_shapes returns 429 with an actionable message" do
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

    {:ok, resp} =
      Req.get(req(), url: "/v1/shape?table=gadgets&offset=-1", headers: limits_auth, retry: false)

    assert resp.status == 429
    assert Jason.decode!(resp.body)["error"] =~ "limit of 1 active shape"
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

  test "DELETE /v1/shape removes the shape when allow_shape_deletion is set" do
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

    {:ok, resumed} =
      Req.get(req(),
        url: "/v1/shape?table=widgets&offset=0_inf&handle=#{handle}",
        headers: auth(),
        retry: false
      )

    assert resumed.status == 409
  end

  test "DELETE /v1/shape returns 404 when disabled" do
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
  end
end
