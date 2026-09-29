defmodule Restdis.Cache.KeyTest do
  use ExUnit.Case, async: true

  alias Restdis.Cache.Key

  describe "encode/decode round-trip" do
    test "table scope" do
      key = Key.build(:table, "users", %{"id" => "eq.1"})
      assert {:ok, ^key} = key |> Key.encode() |> Key.decode()
    end

    test "rpc scope" do
      key = Key.build(:rpc, "my_func", %{"arg" => "val"})
      assert {:ok, ^key} = key |> Key.encode() |> Key.decode()
    end

    test "view scope" do
      key = Key.build(:view, "active_users", %{})
      assert {:ok, ^key} = key |> Key.encode() |> Key.decode()
    end

    test "ident with special characters is preserved" do
      key = Key.build(:table, "my-table_2", %{})
      assert {:ok, ^key} = key |> Key.encode() |> Key.decode()
    end

    test "shape scope" do
      key = Key.build(:shape, "orders", %{})
      assert {:ok, ^key} = key |> Key.encode() |> Key.decode()
    end

    test "ident containing a colon is preserved" do
      key = Key.build(:table, "schema:table", %{})
      assert {:ok, ^key} = key |> Key.encode() |> Key.decode()
    end

    test "raw key encodes as its bare ident and decodes back to a :raw key" do
      key = %Key{scope: :raw, ident: "my-raw-key", params_hash: 0}
      assert Key.encode(key) == "my-raw-key"
      assert {:ok, ^key} = key |> Key.encode() |> Key.decode()
    end
  end

  describe "decode error cases" do
    test "non-pgrst prefix" do
      assert :error = Key.decode("redis:key:123")
    end

    test "wrong number of parts" do
      assert :error = Key.decode("pgrst:t:users")
    end

    test "invalid scope char" do
      assert :error = Key.decode("pgrst:x:users:12345")
    end

    test "non-integer hash" do
      assert :error = Key.decode("pgrst:t:users:notanumber")
    end

    test "negative hash is rejected" do
      assert :error = Key.decode("pgrst:t:users:-1")
    end

    test "signed positive hash is rejected" do
      assert :error = Key.decode("pgrst:t:users:+1")
    end

    test "empty string" do
      assert :error = Key.decode("")
    end

    test "non-binary input" do
      assert :error = Key.decode(nil)
    end
  end

  describe "canonicalization" do
    test "same params in any order produce same hash" do
      key1 = Key.build(:table, "items", %{"a" => "1", "b" => "2"})
      key2 = Key.build(:table, "items", %{"b" => "2", "a" => "1"})
      assert key1 == key2
    end

    test "build/4 query pairs are order-independent" do
      key1 = Key.build(:table, "items", [], [{"a", "1"}, {"b", "2"}])
      key2 = Key.build(:table, "items", [], [{"b", "2"}, {"a", "1"}])
      assert key1 == key2
    end

    test "build/4 keeps duplicate query params distinct from a single param" do
      both = Key.build(:table, "items", [], [{"id", "gt.1"}, {"id", "lt.9"}])
      last = Key.build(:table, "items", [], [{"id", "lt.9"}])
      assert both.params_hash != last.params_hash
    end

    test "build/4 path segments after the ident change the hash but not the ident" do
      bare = Key.build(:rpc, "fn", [], [])
      nested = Key.build(:rpc, "fn", ["x"], [])
      assert nested.ident == "fn"
      assert bare.params_hash != nested.params_hash
    end

    test "build/3 with a params map equals build/4 with no segments and the map's pairs" do
      assert Key.build(:table, "users", %{"id" => "eq.1", "select" => "*"}) ==
               Key.build(:table, "users", [], [{"select", "*"}, {"id", "eq.1"}])
    end

    test "params_hash is SHA-256 of the deterministic canonical term truncated to 128 bits" do
      canonical = {["x"], [{"a", "1"}, {"id", "gt.1"}, {"id", "lt.9"}]}
      digest = :crypto.hash(:sha256, :erlang.term_to_binary(canonical, [:deterministic]))
      <<expected::unsigned-big-integer-size(128), _::binary>> = digest

      key = Key.build(:table, "items", ["x"], [{"id", "lt.9"}, {"a", "1"}, {"id", "gt.1"}])
      assert key.params_hash == expected
      assert {:ok, ^key} = key |> Key.encode() |> Key.decode()
    end
  end
end
