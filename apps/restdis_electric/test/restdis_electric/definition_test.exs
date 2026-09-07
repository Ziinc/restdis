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

  describe "field IN (subquery)" do
    setup do
      TestUtils.put_table("public.parents", %{
        columns: ["id", "archived"],
        primary_key: ["id"],
        replica_identity: :full
      })

      :ok
    end

    test "accepts a plain, non-correlated, bare subquery" do
      assert {:ok, %{filter: filter}} =
               Definition.new("t1", %{
                 "table" => "widgets",
                 "where" => "id IN (SELECT id FROM parents WHERE archived = false)"
               })

      assert {:ok, _pieces} = RestdisElectric.Eval.bare_subquery(filter)
    end

    test "rejects a NOT IN subquery combined with another table's real primary key check" do
      # A bare `NOT IN` is still accepted (`negated` lives on the in_subquery node itself).
      assert {:ok, %{filter: filter}} =
               Definition.new("t1", %{
                 "table" => "widgets",
                 "where" => "id NOT IN (SELECT id FROM parents WHERE archived = false)"
               })

      assert {:ok, %{negated: true}} = RestdisElectric.Eval.bare_subquery(filter)
    end

    test "rejects a subquery with more than one projected column" do
      assert {:error, {:unsupported_where, message}} =
               Definition.new("t1", %{
                 "table" => "widgets",
                 "where" => "id IN (SELECT id, archived FROM parents)"
               })

      assert message =~ "one column"
    end

    test "rejects a subquery with a join" do
      assert {:error, {:unsupported_where, message}} =
               Definition.new("t1", %{
                 "table" => "widgets",
                 "where" => "id IN (SELECT id FROM parents JOIN widgets ON true)"
               })

      assert message =~ "join"
    end

    test "rejects a subquery nested inside a subquery" do
      TestUtils.put_table("public.grandparents", %{
        columns: ["id"],
        primary_key: ["id"],
        replica_identity: :full
      })

      assert {:error, {:unsupported_where, message}} =
               Definition.new("t1", %{
                 "table" => "widgets",
                 "where" =>
                   "id IN (SELECT id FROM parents WHERE id IN (SELECT id FROM grandparents))"
               })

      assert message =~ "nested"
    end

    test "rejects a subquery reading an unknown table" do
      assert {:error, {:unknown_table, "public.nope"}} =
               Definition.new("t1", %{
                 "table" => "widgets",
                 "where" => "id IN (SELECT id FROM nope)"
               })
    end

    test "rejects a correlated subquery, naming the offending column" do
      assert {:error, {:correlated_subquery, column}} =
               Definition.new("t1", %{
                 "table" => "widgets",
                 "where" => "id IN (SELECT id FROM parents WHERE archived = widgets.price)"
               })

      assert column =~ "price"
    end

    test "rejects a subquery clause naming an unknown column of its own table" do
      assert {:error, {:unknown_columns, ["bogus"]}} =
               Definition.new("t1", %{
                 "table" => "widgets",
                 "where" => "id IN (SELECT id FROM parents WHERE bogus = 1)"
               })
    end

    test "accepts a subquery combined with one subquery-free predicate over AND or OR" do
      for where <- [
            "id IN (SELECT id FROM parents WHERE archived = false) AND name = 'x'",
            "name = 'x' AND id IN (SELECT id FROM parents WHERE archived = false)",
            "id IN (SELECT id FROM parents WHERE archived = false) OR name = 'x'",
            "name = 'x' OR id IN (SELECT id FROM parents WHERE archived = false)"
          ] do
        assert {:ok, %{filter: filter}} =
                 Definition.new("t1", %{"table" => "widgets", "where" => where})

        assert {:ok, _pieces} = RestdisElectric.Eval.combined_subquery(filter)
      end
    end

    test "rejects a subquery under a top-level NOT" do
      assert {:error, {:unsupported_where, message}} =
               Definition.new("t1", %{
                 "table" => "widgets",
                 "where" => "NOT (id IN (SELECT id FROM parents WHERE archived = false))"
               })

      assert message =~ "not supported yet"
    end

    test "rejects more than one subquery in a clause" do
      TestUtils.put_table("public.grandparents", %{
        columns: ["id"],
        primary_key: ["id"],
        replica_identity: :full
      })

      assert {:error, {:unsupported_where, message}} =
               Definition.new("t1", %{
                 "table" => "widgets",
                 "where" =>
                   "id IN (SELECT id FROM parents WHERE archived = false) AND " <>
                     "id IN (SELECT id FROM grandparents)"
               })

      assert message =~ "not supported yet"
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

  test "accepts log=changes_only" do
    assert {:ok, %{log_mode: :changes_only}} =
             Definition.new("t1", %{"table" => "widgets", "log" => "changes_only"})
  end

  test "rejects an unknown log value" do
    assert {:error, {:unsupported_log_mode, "batched"}} =
             Definition.new("t1", %{"table" => "widgets", "log" => "batched"})
  end

  test "accepts a retention parameter as a positive integer" do
    assert {:ok, %{retention: 500}} =
             Definition.new("t1", %{"table" => "widgets", "retention" => "500"})
  end

  test "defaults retention to nil when not given" do
    assert {:ok, %{retention: nil}} = Definition.new("t1", %{"table" => "widgets"})
  end

  test "rejects a non-integer retention value" do
    assert {:error, {:invalid_retention, "abc"}} =
             Definition.new("t1", %{"table" => "widgets", "retention" => "abc"})
  end

  test "rejects a zero or negative retention value" do
    assert {:error, {:invalid_retention, "0"}} =
             Definition.new("t1", %{"table" => "widgets", "retention" => "0"})
  end

  test "rejects an empty table string the same as a missing one" do
    assert {:error, {:missing_table, nil}} = Definition.new("t1", %{"table" => ""})
  end

  test "treats an empty columns string as no column list" do
    assert {:ok, %Definition{columns: nil}} =
             Definition.new("t1", %{"table" => "widgets", "columns" => ""})
  end

  test "accepts an explicit replica=default" do
    assert {:ok, %{replica: :default}} =
             Definition.new("t1", %{"table" => "widgets", "replica" => "default"})
  end

  test "accepts an explicit log=full" do
    assert {:ok, %{log_mode: :full}} =
             Definition.new("t1", %{"table" => "widgets", "log" => "full"})
  end

  test "treats an empty where string as no filter" do
    assert {:ok, %{where: nil, filter: nil}} =
             Definition.new("t1", %{"table" => "widgets", "where" => ""})
  end

  test "treats an empty retention string as no retention" do
    assert {:ok, %{retention: nil}} =
             Definition.new("t1", %{"table" => "widgets", "retention" => ""})
  end

  test "treats an empty params string as no params" do
    assert {:ok, %{params: %{}}} =
             Definition.new("t1", %{"table" => "widgets", "params" => ""})
  end

  test "canonical_columns/1 joins an explicit column list" do
    {:ok, definition} = Definition.new("t1", %{"table" => "widgets", "columns" => "id,name"})
    assert Definition.canonical(definition) =~ "columns=id,name"
  end

  test "rejects a schema-qualified table name with an empty table part" do
    assert {:error, {:missing_table, nil}} = Definition.new("t1", %{"table" => "public."})
  end

  test "rejects a non-string table value" do
    assert {:error, {:missing_table, nil}} = Definition.new("t1", %{"table" => 123})
  end

  test "accepts columns already given as a list" do
    assert {:ok, %Definition{columns: ["id", "name"]}} =
             Definition.new("t1", %{"table" => "widgets", "columns" => ["id", "name"]})
  end

  test "rejects a non-string where value" do
    assert {:error, {:invalid_where, message}} =
             Definition.new("t1", %{"table" => "widgets", "where" => 123})

    assert message =~ "must be text"
  end

  test "rejects a non-string retention value" do
    assert {:error, {:invalid_retention, "123"}} =
             Definition.new("t1", %{"table" => "widgets", "retention" => 123})
  end

  test "rejects params given as invalid JSON" do
    assert {:error, {:invalid_where, message}} =
             Definition.new("t1", %{
               "table" => "widgets",
               "where" => "id = $1",
               "params" => "not json"
             })

    assert message =~ "JSON object"
  end

  test "rejects params given as a JSON array instead of an object" do
    assert {:error, {:invalid_where, message}} =
             Definition.new("t1", %{
               "table" => "widgets",
               "where" => "id = $1",
               "params" => "[1,2,3]"
             })

    assert message =~ "JSON object"
  end

  test "rejects params given as a non-map, non-string value" do
    assert {:error, {:invalid_where, message}} =
             Definition.new("t1", %{
               "table" => "widgets",
               "where" => "id = $1",
               "params" => 123
             })

    assert message =~ "JSON object"
  end

  test "canonical/1 is stable for equal definitions and differs for different ones" do
    {:ok, a} = Definition.new("t1", %{"table" => "widgets"})
    {:ok, b} = Definition.new("t1", %{"table" => "widgets"})
    {:ok, c} = Definition.new("t2", %{"table" => "widgets"})

    assert Definition.canonical(a) == Definition.canonical(b)
    assert Definition.canonical(a) != Definition.canonical(c)
  end
end
