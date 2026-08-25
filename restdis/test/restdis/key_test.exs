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
  end

  describe "canonicalization" do
    test "same params in any order produce same hash" do
      key1 = Key.build(:table, "items", %{"a" => "1", "b" => "2"})
      key2 = Key.build(:table, "items", %{"b" => "2", "a" => "1"})
      assert key1 == key2
    end
  end
end
