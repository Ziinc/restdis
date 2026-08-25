defmodule SupaCacherBuster.WAL.RelationCacheTest do
  use ExUnit.Case, async: true

  alias SupaCacherBuster.WAL.RelationCache

  test "new/0 returns empty cache" do
    assert RelationCache.new() == %{}
  end

  test "lookup/2 returns :not_found for unknown OID" do
    assert RelationCache.lookup(RelationCache.new(), 999) == :not_found
  end

  test "update/3 then lookup/2 returns the relation" do
    cols = [%{name: "id", flags: 1}, %{name: "name", flags: 0}]

    cache =
      RelationCache.new()
      |> RelationCache.update(100, %{schema: "public", table: "products", columns: cols})

    assert {:ok, %{schema: "public", table: "products", columns: ^cols}} =
             RelationCache.lookup(cache, 100)
  end

  test "update/3 overwrites existing OID" do
    cols1 = [%{name: "id", flags: 1}]
    cols2 = [%{name: "id", flags: 1}, %{name: "price", flags: 0}]

    cache =
      RelationCache.new()
      |> RelationCache.update(1, %{schema: "public", table: "products", columns: cols1})
      |> RelationCache.update(1, %{schema: "public", table: "products", columns: cols2})

    assert {:ok, %{columns: ^cols2}} = RelationCache.lookup(cache, 1)
  end

  test "multiple OIDs coexist" do
    cache =
      RelationCache.new()
      |> RelationCache.update(1, %{schema: "public", table: "products", columns: []})
      |> RelationCache.update(2, %{schema: "public", table: "orders", columns: []})

    assert {:ok, %{table: "products"}} = RelationCache.lookup(cache, 1)
    assert {:ok, %{table: "orders"}} = RelationCache.lookup(cache, 2)
  end
end
