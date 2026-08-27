defmodule RestdisServer.PGRST.QueryParserTest do
  use ExUnit.Case, async: true

  alias Restdis.Cache.Key
  alias RestdisServer.PGRST.QueryParser

  test "parses table path with query params" do
    assert {:ok, %Key{scope: :table, ident: "users"}, params} =
             QueryParser.parse("/users?id=eq.1&select=name")

    assert params == %{"id" => "eq.1", "select" => "name"}
  end

  test "parses rpc path" do
    assert {:ok, %Key{scope: :rpc, ident: "my_func"}, _} =
             QueryParser.parse("/rpc/my_func")
  end

  test "parses path with no params" do
    assert {:ok, %Key{scope: :table, ident: "products"}, %{}} =
             QueryParser.parse("/products")
  end

  test "canonical key: same params in any order produce same hash" do
    {:ok, key1, _} = QueryParser.parse("/items?b=2&a=1")
    {:ok, key2, _} = QueryParser.parse("/items?a=1&b=2")
    assert key1.params_hash == key2.params_hash
  end

  test "different params produce different keys" do
    {:ok, key1, _} = QueryParser.parse("/items?id=eq.1")
    {:ok, key2, _} = QueryParser.parse("/items?id=eq.2")
    assert key1.params_hash != key2.params_hash
  end
end
