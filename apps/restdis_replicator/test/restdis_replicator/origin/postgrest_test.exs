defmodule RestdisReplicator.Origin.PostgRESTTest do
  use ExUnit.Case

  alias RestdisReplicator.Dataset
  alias RestdisReplicator.Origin.PostgREST

  @stub_name __MODULE__.Finch

  defp dataset(attrs \\ %{}) do
    Dataset.new(Map.merge(%{tenant_id: "t1", table_name: "orders", pk_column: "id"}, attrs))
  end

  defp put_tenant_config(config) do
    Application.put_env(
      :restdis_replicator,
      :tenant_config_lookup,
      {__MODULE__, :lookup, [config]}
    )

    on_exit(fn ->
      Application.put_env(:restdis_replicator, :tenant_config_lookup, nil)
    end)
  end

  def lookup(_tenant_id, config), do: {:ok, config}

  setup do
    Application.put_env(:restdis_replicator, :req_options, plug: {Req.Test, @stub_name})

    on_exit(fn ->
      Application.delete_env(:restdis_replicator, :req_options)
    end)

    :ok
  end

  describe "list_page/3" do
    test "returns {:ok, rows} on a 200 list response" do
      put_tenant_config(%{pgrst_base_url: "http://localhost:9999", pgrst_api_key: "key"})
      body = [%{"id" => 1}, %{"id" => 2}]

      Req.Test.stub(@stub_name, fn conn ->
        assert conn.request_path == "/orders"
        Req.Test.json(conn, body)
      end)

      assert {:ok, ^body} = PostgREST.list_page(dataset(), 0, 2)
    end

    test "wraps a non-list 200 response body in a list" do
      put_tenant_config(%{pgrst_base_url: "http://localhost:9999", pgrst_api_key: "key"})

      Req.Test.stub(@stub_name, fn conn ->
        Req.Test.json(conn, %{"id" => 1})
      end)

      assert {:ok, [%{"id" => 1}]} = PostgREST.list_page(dataset(), 0, 1)
    end

    test "applies the dataset filter as query params" do
      put_tenant_config(%{pgrst_base_url: "http://localhost:9999", pgrst_api_key: "key"})

      Req.Test.stub(@stub_name, fn conn ->
        assert conn.query_string =~ "status=eq.open"
        Req.Test.json(conn, [])
      end)

      assert {:ok, []} = PostgREST.list_page(dataset(%{filter: "status=eq.open"}), 0, 10)
    end

    test "prefers replica_url over pgrst_base_url when present" do
      put_tenant_config(%{
        pgrst_base_url: "http://should-not-be-used",
        replica_url: "http://localhost:9999",
        pgrst_api_key: "key"
      })

      Req.Test.stub(@stub_name, fn conn ->
        Req.Test.json(conn, [])
      end)

      assert {:ok, []} = PostgREST.list_page(dataset(), 0, 10)
    end

    test "returns {:error, {:status, status}} on a non-2xx response" do
      put_tenant_config(%{pgrst_base_url: "http://localhost:9999", pgrst_api_key: "key"})

      Req.Test.stub(@stub_name, fn conn ->
        Plug.Conn.send_resp(conn, 500, "boom")
      end)

      assert {:error, {:status, 500}} = PostgREST.list_page(dataset(), 0, 10)
    end

    test "returns {:error, reason} on a transport error" do
      put_tenant_config(%{pgrst_base_url: "http://localhost:9999", pgrst_api_key: "key"})

      Req.Test.stub(@stub_name, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, %Req.TransportError{}} = PostgREST.list_page(dataset(), 0, 10)
    end

    test "returns the tenant config lookup error when it fails" do
      Application.put_env(:restdis_replicator, :tenant_config_lookup, nil)

      assert {:error, :no_tenant_config_lookup} = PostgREST.list_page(dataset(), 0, 10)
    end
  end

  describe "fetch_row/2" do
    test "returns {:ok, row} when a matching row is found" do
      put_tenant_config(%{pgrst_base_url: "http://localhost:9999", pgrst_api_key: "key"})

      Req.Test.stub(@stub_name, fn conn ->
        assert conn.query_string =~ "id=eq.7"
        Req.Test.json(conn, [%{"id" => 7}])
      end)

      assert {:ok, %{"id" => 7}} = PostgREST.fetch_row(dataset(), "7")
    end

    test "returns :not_found when no row matches" do
      put_tenant_config(%{pgrst_base_url: "http://localhost:9999", pgrst_api_key: "key"})

      Req.Test.stub(@stub_name, fn conn ->
        Req.Test.json(conn, [])
      end)

      assert :not_found = PostgREST.fetch_row(dataset(), "missing")
    end

    test "returns an error tuple when tenant config lookup fails" do
      Application.put_env(:restdis_replicator, :tenant_config_lookup, nil)

      assert {:error, :no_tenant_config_lookup} = PostgREST.fetch_row(dataset(), "1")
    end
  end
end
