defmodule RestdisServer.PostgREST.FetcherTest do
  use ExUnit.Case

  alias Restdis.Cache.Key
  alias RestdisServer.PostgREST.Fetcher
  alias RestdisServer.PostgREST.Fetcher.Req, as: FetcherReq

  @tenant_id "fetcher-test-tenant"

  defp base_config do
    %{
      pgrst_base_url: "http://localhost:9999",
      pgrst_api_key: "test_api_key",
      replica_url: nil
    }
  end

  defp stub_name, do: RestdisServer.Finch

  describe "path_for/1" do
    test "table scope produces /ident" do
      key = %Key{scope: :table, ident: "users"}
      assert Fetcher.path_for(key) == "/users"
    end

    test "rpc scope produces /rpc/ident" do
      key = %Key{scope: :rpc, ident: "get_user"}
      assert Fetcher.path_for(key) == "/rpc/get_user"
    end

    test "view scope produces /ident" do
      key = %Key{scope: :view, ident: "active_users"}
      assert Fetcher.path_for(key) == "/active_users"
    end

    test "encodes special characters in ident" do
      key = %Key{scope: :table, ident: "my table"}
      assert Fetcher.path_for(key) == "/my%20table"
    end

    test "includes query string when present" do
      key = %Key{scope: :table, ident: "users"}
      assert Fetcher.path_for(key, "id=eq.1") == "/users?id=eq.1"
    end

    test "omits query string when empty" do
      key = %Key{scope: :table, ident: "users"}
      assert Fetcher.path_for(key, "") == "/users"
    end

    test "rpc scope includes query string when present" do
      key = %Key{scope: :rpc, ident: "get_user"}
      assert Fetcher.path_for(key, "id=1") == "/rpc/get_user?id=1"
    end
  end

  describe "FetcherReq.fetch/3" do
    test "200 returns {:ok, body} with decoded JSON" do
      body = [%{"id" => 1, "name" => "Alice"}]

      Req.Test.stub(stub_name(), fn conn ->
        Req.Test.json(conn, body)
      end)

      assert {:ok, ^body} =
               FetcherReq.fetch(@tenant_id, %Key{scope: :table, ident: "users"}, base_config())
    end

    test "500 returns {:error, {:status, 500}}" do
      Req.Test.stub(stub_name(), fn conn ->
        Plug.Conn.send_resp(conn, 500, Jason.encode!(%{message: "internal error"}))
      end)

      assert {:error, {:status, 500}} =
               FetcherReq.fetch(@tenant_id, %Key{scope: :table, ident: "users"}, base_config())
    end

    test "non-200 status returns {:error, {:status, status}}" do
      Req.Test.stub(stub_name(), fn conn ->
        Plug.Conn.send_resp(conn, 404, Jason.encode!(%{message: "not found"}))
      end)

      assert {:error, {:status, 404}} =
               FetcherReq.fetch(@tenant_id, %Key{scope: :table, ident: "missing"}, base_config())
    end

    test "transport error returns {:error, reason}" do
      Req.Test.stub(stub_name(), fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               FetcherReq.fetch(@tenant_id, %Key{scope: :table, ident: "users"}, base_config())
    end

    test "apikey header is included in request" do
      Req.Test.stub(stub_name(), fn conn ->
        [apikey] = Plug.Conn.get_req_header(conn, "apikey")
        assert apikey == "test_api_key"
        Req.Test.json(conn, [])
      end)

      FetcherReq.fetch(@tenant_id, %Key{scope: :table, ident: "users"}, base_config())
    end

    test "replica_url overrides pgrst_base_url" do
      config = Map.put(base_config(), :replica_url, "http://replica:9998")

      Req.Test.stub(stub_name(), fn conn ->
        assert conn.host == "replica"
        assert conn.port == 9998
        Req.Test.json(conn, [])
      end)

      assert {:ok, _} = FetcherReq.fetch(@tenant_id, %Key{scope: :table, ident: "users"}, config)
    end

    test "uses pgrst_base_url when replica_url is nil" do
      Req.Test.stub(stub_name(), fn conn ->
        assert conn.host == "localhost"
        assert conn.port == 9999
        Req.Test.json(conn, [])
      end)

      assert {:ok, _} =
               FetcherReq.fetch(@tenant_id, %Key{scope: :table, ident: "users"}, base_config())
    end
  end

  describe "Fetcher.fetch/3 dispatcher" do
    test "delegates to configured impl" do
      body = %{"result" => true}

      Req.Test.stub(stub_name(), fn conn ->
        Req.Test.json(conn, body)
      end)

      assert {:ok, ^body} =
               Fetcher.fetch(@tenant_id, %Key{scope: :table, ident: "products"}, base_config())
    end
  end

  describe "FetcherReq.fetch/3 with query string" do
    alias RestdisServer.QueryStore

    test "forwards the query string recorded in the QueryStore to the outbound request" do
      key = Key.build(:table, "users", %{"id" => "eq.1"})
      QueryStore.put(@tenant_id, Key.encode(key), "id=eq.1")

      Req.Test.stub(stub_name(), fn conn ->
        assert conn.query_string == "id=eq.1"
        Req.Test.json(conn, [%{"id" => 1}])
      end)

      assert {:ok, _} = FetcherReq.fetch(@tenant_id, key, base_config())
    end

    test "different query strings on the same ident hit different outbound queries" do
      key1 = Key.build(:table, "users", %{"id" => "eq.1"})
      key2 = Key.build(:table, "users", %{"id" => "eq.2"})
      QueryStore.put(@tenant_id, Key.encode(key1), "id=eq.1")
      QueryStore.put(@tenant_id, Key.encode(key2), "id=eq.2")

      Req.Test.stub(stub_name(), fn conn ->
        Req.Test.json(conn, [%{"query" => conn.query_string}])
      end)

      assert {:ok, [%{"query" => "id=eq.1"}]} = FetcherReq.fetch(@tenant_id, key1, base_config())
      assert {:ok, [%{"query" => "id=eq.2"}]} = FetcherReq.fetch(@tenant_id, key2, base_config())
    end

    test "no recorded query string means no query string reaches the origin" do
      key = %Key{scope: :table, ident: "users", params_hash: 0}

      Req.Test.stub(stub_name(), fn conn ->
        assert conn.query_string == ""
        Req.Test.json(conn, [])
      end)

      assert {:ok, _} = FetcherReq.fetch(@tenant_id, key, base_config())
    end
  end
end
