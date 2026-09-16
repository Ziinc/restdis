defmodule RestdisServer.PGRST.QueryParserTest do
  use ExUnit.Case, async: true

  alias Restdis.Cache.Key
  alias RestdisServer.PGRST.QueryParser

  test "parses table path with query params" do
    assert {:ok, %Key{scope: :table, ident: "users"}, params} =
             QueryParser.parse("t1", "/users?id=eq.1&select=name")

    assert params == %{"id" => "eq.1", "select" => "name"}
  end

  test "parses rpc path" do
    assert {:ok, %Key{scope: :rpc, ident: "my_func"}, _} =
             QueryParser.parse("t1", "/rpc/my_func")
  end

  test "parses path with no params" do
    assert {:ok, %Key{scope: :table, ident: "products"}, %{}} =
             QueryParser.parse("t1", "/products")
  end

  test "canonical key: same params in any order produce same hash" do
    {:ok, key1, _} = QueryParser.parse("t1", "/items?b=2&a=1")
    {:ok, key2, _} = QueryParser.parse("t1", "/items?a=1&b=2")
    assert key1.params_hash == key2.params_hash
  end

  test "different params produce different keys" do
    {:ok, key1, _} = QueryParser.parse("t1", "/items?id=eq.1")
    {:ok, key2, _} = QueryParser.parse("t1", "/items?id=eq.2")
    assert key1.params_hash != key2.params_hash
  end

  test "records the raw query string in the QueryStore for later fetches" do
    {:ok, key, _} = QueryParser.parse("t1", "/users?id=eq.1")
    wire_key = Key.encode(key)
    assert RestdisServer.QueryStore.get("t1", wire_key) == "id=eq.1"
  end

  test "records an empty query string when the path has no query" do
    {:ok, key, _} = QueryParser.parse("t1", "/products")
    wire_key = Key.encode(key)
    assert RestdisServer.QueryStore.get("t1", wire_key) == ""
  end

  test "a path with no path segment at all is rejected" do
    assert {:error, :missing_path} = QueryParser.parse("t1", "?id=eq.1")
  end

  test "an empty path is rejected" do
    assert {:error, :empty_path} = QueryParser.parse("t1", "/")
  end
end
