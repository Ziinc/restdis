defmodule RestdisElectric.DefinitionTest do
  use ExUnit.Case, async: false

  alias RestdisElectric.Definition
  alias RestdisElectric.TestUtils

  setup do
    TestUtils.put_table("public.widgets", %{
      columns: ["id", "name", "price"],
      primary_key: ["id"],
      replica_identity: :full
    })

    :ok
  end

  test "builds a definition for a known table" do
    assert {:ok, %Definition{schema: "public", table: "widgets"}} =
             Definition.new("t1", %{"table" => "widgets"})
  end

  test "accepts a schema-qualified table name" do
    assert {:ok, %Definition{schema: "public", table: "widgets"}} =
             Definition.new("t1", %{"table" => "public.widgets"})
  end

  test "rejects a missing table parameter" do
    assert {:error, {:missing_table, nil}} = Definition.new("t1", %{})
  end

  test "rejects an unknown table" do
    assert {:error, {:unknown_table, "public.nope"}} = Definition.new("t1", %{"table" => "nope"})
  end

  test "rejects a table without REPLICA IDENTITY FULL" do
    TestUtils.put_table("public.no_identity", %{
      columns: ["id"],
      primary_key: ["id"],
      replica_identity: :default
    })

    assert {:error, {:missing_replica_identity, "public.no_identity"}} =
             Definition.new("t1", %{"table" => "no_identity"})
  end

  test "accepts a column list that includes the primary key" do
    assert {:ok, %Definition{columns: ["id", "name"]}} =
             Definition.new("t1", %{"table" => "widgets", "columns" => "id,name"})
  end

  test "rejects a column list that omits the primary key" do
    assert {:error, {:missing_primary_key, ["id"]}} =
             Definition.new("t1", %{"table" => "widgets", "columns" => "name"})
  end

  test "rejects unknown columns" do
    assert {:error, {:unknown_columns, ["bogus"]}} =
             Definition.new("t1", %{"table" => "widgets", "columns" => "id,bogus"})
  end

  test "rejects a where clause (not yet supported)" do
    assert {:error, {:unsupported_where, "id = 1"}} =
             Definition.new("t1", %{"table" => "widgets", "where" => "id = 1"})
  end

  test "rejects replica=full (not yet supported)" do
    assert {:error, {:unsupported_replica, "full"}} =
             Definition.new("t1", %{"table" => "widgets", "replica" => "full"})
  end

  test "rejects log=changes_only (not yet supported)" do
    assert {:error, {:unsupported_log_mode, "changes_only"}} =
             Definition.new("t1", %{"table" => "widgets", "log" => "changes_only"})
  end

  test "canonical/1 is stable for equal definitions and differs for different ones" do
    {:ok, a} = Definition.new("t1", %{"table" => "widgets"})
    {:ok, b} = Definition.new("t1", %{"table" => "widgets"})
    {:ok, c} = Definition.new("t2", %{"table" => "widgets"})

    assert Definition.canonical(a) == Definition.canonical(b)
    assert Definition.canonical(a) != Definition.canonical(c)
  end
end
