defmodule SupaCacherReplicator.DatasetTest do
  use ExUnit.Case, async: true

  alias Restdis.Cache.Key
  alias SupaCacherReplicator.Dataset

  test "new/1 builds a dataset from a tenant table config map" do
    dataset =
      Dataset.new(%{
        tenant_id: "t1",
        schema: "public",
        table_name: "products",
        pk_column: "id",
        filter: "active=eq.true"
      })

    assert %Dataset{
             tenant_id: "t1",
             schema: "public",
             table: "products",
             pk_column: "id",
             filter: "active=eq.true"
           } = dataset
  end

  test "new/1 defaults schema and pk_column" do
    dataset = Dataset.new(%{tenant_id: "t1", table_name: "products"})

    assert dataset.schema == "public"
    assert dataset.pk_column == "id"
    assert dataset.filter == nil
  end

  test "cache_key/2 is deterministic and independent of the primary key type" do
    key = Dataset.cache_key("products", 42)

    assert %Key{scope: :table, ident: "products"} = key
    assert key == Dataset.cache_key("products", "42")
    assert key != Dataset.cache_key("products", 43)
    assert key != Dataset.cache_key("orders", 42)
  end

  test "cache_key/2 accepts a dataset" do
    dataset = Dataset.new(%{tenant_id: "t1", table_name: "products"})

    assert Dataset.cache_key(dataset, 42) == Dataset.cache_key("products", 42)
  end

  test "parse_wire_key/1 splits a replicated KV key" do
    assert {:ok, {"products", "42"}} = Dataset.parse_wire_key("products:42")
    assert {:ok, {"products", "a:b"}} = Dataset.parse_wire_key("products:a:b")
  end

  test "parse_wire_key/1 rejects malformed and pgrst keys" do
    assert :error = Dataset.parse_wire_key("products")
    assert :error = Dataset.parse_wire_key("products:")
    assert :error = Dataset.parse_wire_key(":42")
    assert :error = Dataset.parse_wire_key("pgrst:t:products:123")
  end

  test "pk_of/2 reads the primary key from a row" do
    dataset = Dataset.new(%{tenant_id: "t1", table_name: "orders", pk_column: "order_id"})

    assert Dataset.pk_of(dataset, %{"order_id" => 7, "total" => 1}) == "7"
    assert Dataset.pk_of(dataset, %{"total" => 1}) == nil
  end
end
