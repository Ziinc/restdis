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

  describe "where" do
    test "accepts and compiles a supported clause" do
      assert {:ok, definition} =
               Definition.new("t1", %{"table" => "widgets", "where" => "id = 1"})

      assert definition.where == "id = 1"
      assert definition.filter.source == "id = 1"
    end

    test "rejects an unsupported construct at subscription time, naming it" do
      assert {:error, {:unsupported_where, construct}} =
               Definition.new("t1", %{"table" => "widgets", "where" => "now() > id"})

      assert construct =~ "now"
    end

    test "rejects a clause that does not parse" do
      assert {:error, {:invalid_where, _}} =
               Definition.new("t1", %{"table" => "widgets", "where" => "id = = 1"})
    end

    test "rejects a clause naming a column the table does not have" do
      assert {:error, {:unknown_columns, ["bogus"]}} =
               Definition.new("t1", %{"table" => "widgets", "where" => "bogus = 1"})
    end

    test "accepts a column qualified by table or by schema and table" do
      assert {:ok, _} =
               Definition.new("t1", %{"table" => "widgets", "where" => "widgets.id = 1"})

      assert {:ok, _} =
               Definition.new("t1", %{"table" => "widgets", "where" => "public.widgets.id = 1"})
    end

    test "binds params given in the bracket form and as JSON" do
      assert {:ok, bracket} =
               Definition.new("t1", %{
                 "table" => "widgets",
                 "where" => "id = $1",
                 "params" => %{"1" => "3"}
               })

      assert {:ok, json} =
               Definition.new("t1", %{
                 "table" => "widgets",
                 "where" => "id = $1",
                 "params" => ~s({"1": "3"})
               })

      assert bracket.params == json.params
    end

    test "rejects a placeholder with no value" do
      assert {:error, {:invalid_where, message}} =
               Definition.new("t1", %{"table" => "widgets", "where" => "id = $1"})

      assert message =~ "$1"
    end

    test "params change the handle, so two bindings are two shapes" do
      {:ok, a} =
        Definition.new("t1", %{
          "table" => "widgets",
          "where" => "id = $1",
          "params" => %{"1" => "1"}
        })

      {:ok, b} =
        Definition.new("t1", %{
          "table" => "widgets",
          "where" => "id = $1",
          "params" => %{"1" => "2"}
        })

      assert Definition.canonical(a) != Definition.canonical(b)
    end
  end

  test "accepts replica=full" do
    assert {:ok, %{replica: :full}} =
             Definition.new("t1", %{"table" => "widgets", "replica" => "full"})
  end

  test "rejects an unknown replica value" do
    assert {:error, {:unsupported_replica, "partial"}} =
             Definition.new("t1", %{"table" => "widgets", "replica" => "partial"})
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
