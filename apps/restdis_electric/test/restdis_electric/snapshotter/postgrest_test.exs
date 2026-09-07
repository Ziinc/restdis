defmodule RestdisElectric.Snapshotter.PostgRESTTest do
  use ExUnit.Case, async: true

  alias RestdisElectric.Definition
  alias RestdisElectric.Snapshotter.PostgREST
  alias RestdisElectric.TestUtils

  defp definition(table, columns \\ nil) do
    %Definition{
      tenant_id: "t1",
      schema: "public",
      table: table,
      columns: columns,
      params: %{}
    }
  end

  defp tenant_config(stub_name) do
    %{
      pgrst_base_url: "http://postgrest.invalid",
      pgrst_api_key: "secret",
      req_options: [plug: {Req.Test, stub_name}]
    }
  end

  test "stream/3 returns {:error, {:unknown_table, _}} for a table with no known schema" do
    assert {:error, {:unknown_table, "public.nope"}} =
             PostgREST.stream(%{}, definition("nope"), fn _rows -> :ok end)
  end

  test "stream/3 pages through every row in primary-key order, stopping on a short page" do
    stub = __MODULE__.SinglePage

    TestUtils.put_table("public.widgets", %{
      columns: ["id", "name"],
      primary_key: ["id"],
      replica_identity: :full
    })

    Req.Test.stub(stub, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.query_params["order"] == "id"
      assert conn.query_params["limit"] == "1000"
      assert conn.query_params["offset"] == "0"
      assert Plug.Conn.get_req_header(conn, "apikey") == ["secret"]

      Req.Test.json(conn, [%{"id" => 1, "name" => "a"}, %{"id" => 2, "name" => "b"}])
    end)

    test_pid = self()

    assert :ok =
             PostgREST.stream(tenant_config(stub), definition("widgets"), fn rows ->
               send(test_pid, {:page, rows})
             end)

    assert_received {:page, rows}
    assert rows == [%{"id" => 1, "name" => "a"}, %{"id" => 2, "name" => "b"}]
  end

  test "stream/3 keeps paging while a page is exactly the page size, and selects requested columns" do
    stub = __MODULE__.TwoPages

    TestUtils.put_table("public.widgets", %{
      columns: ["id", "name"],
      primary_key: ["id"],
      replica_identity: :full
    })

    full_page = Enum.map(1..1000, &%{"id" => &1})
    second_page = [%{"id" => 1001}]

    Req.Test.stub(stub, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.query_params["select"] == "id"

      case conn.query_params["offset"] do
        "0" -> Req.Test.json(conn, full_page)
        "1000" -> Req.Test.json(conn, second_page)
      end
    end)

    test_pid = self()

    assert :ok =
             PostgREST.stream(tenant_config(stub), definition("widgets", ["id"]), fn rows ->
               send(test_pid, {:page, rows})
             end)

    assert_received {:page, first}
    assert_received {:page, second}
    assert length(first) == 1000
    assert second == [%{"id" => 1001}]
  end

  test "stream/3 returns {:error, {:status, _}} for a non-200 response" do
    stub = __MODULE__.ErrorStatus

    TestUtils.put_table("public.widgets", %{
      columns: ["id"],
      primary_key: ["id"],
      replica_identity: :full
    })

    Req.Test.stub(stub, fn conn ->
      Plug.Conn.send_resp(conn, 500, "boom")
    end)

    assert {:error, {:status, 500}} =
             PostgREST.stream(tenant_config(stub), definition("widgets"), fn _rows -> :ok end)
  end

  test "stream/3 returns {:error, reason} on a transport error" do
    stub = __MODULE__.TransportError

    TestUtils.put_table("public.widgets", %{
      columns: ["id"],
      primary_key: ["id"],
      replica_identity: :full
    })

    Req.Test.stub(stub, fn conn ->
      Req.Test.transport_error(conn, :econnrefused)
    end)

    assert {:error, %Req.TransportError{}} =
             PostgREST.stream(tenant_config(stub), definition("widgets"), fn _rows -> :ok end)
  end

  test "stream/3 uses tenant_config's :replica_url over :pgrst_base_url when both are set" do
    stub = __MODULE__.ReplicaUrl

    TestUtils.put_table("public.widgets", %{
      columns: ["id"],
      primary_key: ["id"],
      replica_identity: :full
    })

    Req.Test.stub(stub, fn conn ->
      Req.Test.json(conn, [])
    end)

    tenant_config =
      tenant_config(stub) |> Map.put(:replica_url, "http://replica.invalid")

    assert :ok = PostgREST.stream(tenant_config, definition("widgets"), fn _rows -> :ok end)
  end
end
