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

    test "malformed percent-encoding in the ident is rejected" do
      assert :error = Key.decode("pgrst:t:%zz:0")
    end

    test "a percent-encoded path traversal ident is rejected" do
      assert :error = Key.decode("pgrst:t:..%2F..%2Fauth%2Fv1%2Fadmin%2Fusers:0")
    end
  end

  @invalid_idents ["", ".", "..", "a/b", "a\\b", "a?b", "a#b", "a%b", "a\nb", "a\0b", "a\x7Fb"]

  describe "ident validation" do
    for ident <- @invalid_idents do
      test "decode/1 rejects the ident #{inspect(ident)} in every pgrst scope" do
        encoded = URI.encode(unquote(ident), &URI.char_unreserved?/1)

        for wire_scope <- ["t", "r", "v", "s"] do
          assert :error = Key.decode("pgrst:#{wire_scope}:#{encoded}:0")
        end
      end

      test "build/3 raises ArgumentError for the ident #{inspect(ident)}" do
        assert_raise ArgumentError, fn -> Key.build(:table, unquote(ident), %{}) end
      end

      test "valid_ident?/1 is false for #{inspect(ident)}" do
        refute Key.valid_ident?(unquote(ident))
      end
    end

    test "valid_ident?/1 is true for ordinary PostgREST identifiers" do
      for ident <- ["users", "my-table_2", "public.users", "schema:table", "my table", "a..b"] do
        assert Key.valid_ident?(ident)
      end
    end
  end

  describe "canonicalization" do
    test "same params in any order produce same hash" do
      key1 = Key.build(:table, "items", %{"a" => "1", "b" => "2"})
      key2 = Key.build(:table, "items", %{"b" => "2", "a" => "1"})
      assert key1 == key2
    end
  end
end
