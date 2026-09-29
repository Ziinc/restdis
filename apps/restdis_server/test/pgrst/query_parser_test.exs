defmodule RestdisServer.PGRST.QueryParserTest do
  use ExUnit.Case, async: true

  alias Restdis.Cache.Key
  alias RestdisServer.PGRST.QueryParser

  test "parses table path with query params" do
    assert {:ok, %Key{scope: :table, ident: "users"}, params} =
             QueryParser.parse("t1", "/users?id=eq.1&select=name", "cred")

    assert params == %{"id" => "eq.1", "select" => "name"}
  end

  test "parses rpc path" do
    assert {:ok, %Key{scope: :rpc, ident: "my_func"}, _} =
             QueryParser.parse("t1", "/rpc/my_func", "cred")
  end

  test "parses path with no params" do
    assert {:ok, %Key{scope: :table, ident: "products"}, %{}} =
             QueryParser.parse("t1", "/products", "cred")
  end

  test "canonical key: same params in any order produce same hash" do
    {:ok, key1, _} = QueryParser.parse("t1", "/items?b=2&a=1", "cred")
    {:ok, key2, _} = QueryParser.parse("t1", "/items?a=1&b=2", "cred")
    assert key1.params_hash == key2.params_hash
  end

  test "different params produce different keys" do
    {:ok, key1, _} = QueryParser.parse("t1", "/items?id=eq.1", "cred")
    {:ok, key2, _} = QueryParser.parse("t1", "/items?id=eq.2", "cred")
    assert key1.params_hash != key2.params_hash
  end

  test "duplicate query params produce a different key than the last one alone" do
    {:ok, both, _} = QueryParser.parse("t1", "/items?id=gt.1&id=lt.9", "cred")
    {:ok, last, _} = QueryParser.parse("t1", "/items?id=lt.9", "cred")
    assert both.params_hash != last.params_hash
  end

  test "path segments after the table ident produce a different key with the same ident" do
    {:ok, bare, _} = QueryParser.parse("t1", "/widgets", "cred")
    {:ok, nested, _} = QueryParser.parse("t1", "/widgets/extra", "cred")
    assert nested.ident == "widgets"
    assert bare.params_hash != nested.params_hash
  end

  test "path segments after the rpc ident produce a different key with the same ident" do
    {:ok, bare, _} = QueryParser.parse("t1", "/rpc/fn", "cred")
    {:ok, nested, _} = QueryParser.parse("t1", "/rpc/fn/x", "cred")
    assert nested.ident == "fn"
    assert bare.params_hash != nested.params_hash
  end

  test "the same path under two credentials yields two wire keys with the same ident" do
    {:ok, key_a, params_a} = QueryParser.parse("t1", "/users?id=eq.1", "cred-a")
    {:ok, key_b, params_b} = QueryParser.parse("t1", "/users?id=eq.1", "cred-b")

    assert Key.encode(key_a) != Key.encode(key_b)
    assert key_a.ident == "users" and key_b.ident == "users"
    assert params_a == %{"id" => "eq.1"} and params_b == params_a
  end

  test "a parsed key hashes a SHA-256 fingerprint of the credential into the params" do
    {:ok, key, _} = QueryParser.parse("t1", "/users?select=name&id=eq.1", "cred")
    fingerprint = Base.encode16(:crypto.hash(:sha256, "cred"))

    assert key ==
             Key.build(:table, "users", %{
               "id" => "eq.1",
               "select" => "name",
               "__credential" => fingerprint
             })
  end

  test "records the credential in the QueryStore for later fetches" do
    {:ok, key, _} = QueryParser.parse("t1", "/users?id=eq.3", "cred-c")
    assert RestdisServer.QueryStore.credential("t1", Key.encode(key)) == "cred-c"
  end

  test "records the raw query string in the QueryStore for later fetches" do
    {:ok, key, _} = QueryParser.parse("t1", "/users?id=eq.1", "cred")
    wire_key = Key.encode(key)
    assert RestdisServer.QueryStore.get("t1", wire_key) == "id=eq.1"
  end

  test "records an empty query string when the path has no query" do
    {:ok, key, _} = QueryParser.parse("t1", "/products", "cred")
    wire_key = Key.encode(key)
    assert RestdisServer.QueryStore.get("t1", wire_key) == ""
  end

  test "a path with no path segment at all is rejected" do
    assert {:error, :missing_path} = QueryParser.parse("t1", "?id=eq.1", "cred")
  end

  test "an empty path is rejected" do
    assert {:error, :empty_path} = QueryParser.parse("t1", "/", "cred")
  end

  test "invalidate_by_row invalidates the entries of every credential for the row" do
    tenant_id = "parser_inv_#{System.unique_integer([:positive])}"
    {:ok, key_a, _} = QueryParser.parse(tenant_id, "/widgets?select=*", "cred-a")
    {:ok, key_b, _} = QueryParser.parse(tenant_id, "/widgets?select=*", "cred-b")
    Restdis.Cache.put(tenant_id, key_a, [%{"id" => 42}])
    Restdis.Cache.put(tenant_id, key_b, [%{"id" => 42}])

    Restdis.Cache.invalidate_by_row(tenant_id, "widgets", 42)

    assert :miss = Restdis.Cache.get(tenant_id, key_a)
    assert :miss = Restdis.Cache.get(tenant_id, key_b)
    Restdis.Cache.flush_tenant(tenant_id)
  end
end
