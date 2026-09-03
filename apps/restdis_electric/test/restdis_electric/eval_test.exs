defmodule RestdisElectric.EvalTest do
  use ExUnit.Case, async: true

  alias RestdisElectric.Eval

  @row %{
    "id" => 7,
    "name" => "Alice",
    "email" => nil,
    "score" => 4.5,
    "active" => true,
    "tags" => ["red", "blue"]
  }

  defp matches?(where, params \\ %{}) do
    {:ok, compiled} = Eval.compile(where, params)
    Eval.matches?(compiled, @row)
  end

  describe "the supported subset" do
    test "comparison operators" do
      assert matches?("id = 7")
      assert matches?("id <> 8")
      assert matches?("id != 8")
      assert matches?("id < 8")
      assert matches?("id <= 7")
      assert matches?("id > 6")
      assert matches?("id >= 7")
      refute matches?("id = 8")
    end

    test "logical operators, with Postgres's three-valued logic" do
      assert matches?("id = 7 AND name = 'Alice'")
      assert matches?("id = 8 OR name = 'Alice'")
      assert matches?("NOT (id = 8)")
      # NULL AND TRUE is NULL, which WHERE treats as no match.
      refute matches?("email = 'x' AND id = 7")
      # NULL OR TRUE is TRUE.
      assert matches?("email = 'x' OR id = 7")
      refute matches?("NOT (email = 'x')")
    end

    test "arithmetic and bitwise operators" do
      assert matches?("id + 1 = 8")
      assert matches?("id - 1 = 6")
      assert matches?("id * 2 = 14")
      # Integer division truncates, as it does in Postgres.
      assert matches?("id / 2 = 3")
      assert matches?("id % 2 = 1")
      assert matches?("id & 1 = 1")
      assert matches?("id | 8 = 15")
      assert matches?("id # 1 = 6")
      assert matches?("id << 1 = 14")
      assert matches?("id >> 1 = 3")
    end

    test "LIKE and ILIKE" do
      assert matches?("name LIKE 'Ali%'")
      refute matches?("name LIKE 'ali%'")
      assert matches?("name ILIKE 'ali%'")
      assert matches?("name LIKE 'A_ice'")
      assert matches?("name NOT LIKE 'Bob%'")
      # A wildcard in the value must not act as a wildcard in the pattern.
      assert matches?("name NOT LIKE '%_%_%_%_%_%_'")
    end

    test "array operators" do
      assert matches?("tags @> ARRAY['red']")
      refute matches?("tags @> ARRAY['red', 'green']")
      assert matches?("tags <@ ARRAY['red', 'blue', 'green']")
      assert matches?("tags && ARRAY['green', 'blue']")
      refute matches?("tags && ARRAY['green']")
    end

    test "null and boolean tests" do
      assert matches?("email IS NULL")
      assert matches?("name IS NOT NULL")
      assert matches?("active IS TRUE")
      assert matches?("active IS NOT FALSE")
      refute matches?("active IS FALSE")
      assert matches?("email IS NOT TRUE")
      assert matches?("(email = 'x') IS UNKNOWN")
      assert matches?("active IS NOT UNKNOWN")
    end

    test "IN and NOT IN" do
      assert matches?("id IN (1, 7, 9)")
      refute matches?("id IN (1, 9)")
      assert matches?("id NOT IN (1, 9)")
      # NULL in the list makes a non-match unknown, so the row does not match.
      refute matches?("id NOT IN (1, NULL)")
    end

    test "BETWEEN" do
      assert matches?("id BETWEEN 1 AND 7")
      refute matches?("id BETWEEN 8 AND 10")
      assert matches?("id NOT BETWEEN 8 AND 10")
    end

    test "ANY and ALL" do
      assert matches?("'red' = ANY(tags)")
      refute matches?("'green' = ANY(tags)")
      assert matches?("id = ANY(ARRAY[6, 7])")
      assert matches?("id > ALL(ARRAY[1, 2])")
      refute matches?("id > ALL(ARRAY[1, 99])")
    end

    test "the supported functions" do
      assert matches?("lower(name) = 'alice'")
      assert matches?("upper(name) = 'ALICE'")
      assert matches?("coalesce(email, name) = 'Alice'")
      assert matches?("greatest(id, 3) = 7")
      assert matches?("least(id, 3) = 3")
      # greatest/least ignore NULL arguments.
      assert matches?("greatest(email, name) = 'Alice'")
    end
  end

  describe "params" do
    test "binds $1 placeholders without interpolating them" do
      assert matches?("id = $1", %{"1" => "7"})
      assert matches?("name = $1", %{"1" => "Alice"})
      refute matches?("name = $1", %{"1" => "Bob"})
    end

    test "a value that looks like SQL stays a value" do
      refute matches?("name = $1", %{"1" => "Alice' OR '1'='1"})
    end

    test "an unbound placeholder is rejected at compile time" do
      assert {:error, {:invalid_where, message}} = Eval.compile("id = $2", %{"1" => "7"})
      assert message =~ "$2"
    end

    test "integer keys are accepted as well as the query-string form" do
      assert matches?("id = $1", %{1 => 7})
    end
  end

  describe "rejection" do
    for {where, fragment} <- [
          {"now() > id", "now"},
          {"count(id) > 1", "count"},
          {"data->>'a' = 'b'", "->"},
          {"id::text = '7'", "TEXT"},
          {"id IN (SELECT 1)", "SELECT"},
          {"to_tsvector(name) @@ to_tsquery('a')", "tsvector"},
          {"name || 'x' = 'Alicex'", "||"},
          {"range @> 3", "range"}
        ] do
      test "rejects #{where}" do
        assert {:error, {kind, description}} = Eval.compile(unquote(where), %{})
        assert kind in [:unsupported_where, :invalid_where]
        assert description =~ unquote(fragment) or description != ""
      end
    end

    test "a clause that does not parse is an invalid_where, not an unsupported_where" do
      assert {:error, {:invalid_where, _}} = Eval.compile("id = = =", %{})
    end

    test "an oversized clause is refused before it is parsed" do
      huge = "id = 1 AND " <> String.duplicate("name = 'x' AND ", 2_000) <> "id = 1"
      assert {:error, {:invalid_where, message}} = Eval.compile(huge, %{})
      assert message =~ "limit"
    end
  end

  describe "field IN (subquery)" do
    test "compiles, reports only the outer column, and cannot be decided from one row" do
      assert {:ok, compiled} =
               Eval.compile("id IN (SELECT id FROM parents WHERE archived = false)", %{})

      assert Eval.columns(compiled) == ["id"]
      refute matches?("id IN (SELECT id FROM parents WHERE archived = false)")
    end

    test "subqueries/1 returns the subquery's table, column, and inner selection" do
      {:ok, compiled} =
        Eval.compile("id IN (SELECT parent_id FROM parents WHERE archived = false)", %{})

      assert [{"parents", "parent_id", selection}] = Eval.subqueries(compiled)
      assert selection == {:binop, "=", {:ident, "archived"}, {:lit, {:bool_, false}}}
    end

    test "subqueries/1 finds a subquery nested inside AND, OR, and NOT" do
      for where <- [
            "id IN (SELECT id FROM parents) AND name = 'x'",
            "id IN (SELECT id FROM parents) OR name = 'x'",
            "NOT (id IN (SELECT id FROM parents))"
          ] do
        {:ok, compiled} = Eval.compile(where, %{})
        assert [{"parents", "id", :none}] = Eval.subqueries(compiled)
      end
    end

    test "a subquery whose own structure is unsupported is rejected the same way as anything else" do
      assert {:error, {:unsupported_where, message}} =
               Eval.compile("id IN (SELECT id, name FROM parents)", %{})

      assert message =~ "one column"
    end
  end

  describe "matches?/2" do
    test "a nil clause matches every row but never a missing row" do
      assert Eval.matches?(nil, @row)
      refute Eval.matches?(nil, nil)
    end

    test "a missing row never matches" do
      {:ok, compiled} = Eval.compile("id IS NULL", %{})
      refute Eval.matches?(compiled, nil)
    end

    test "columns/1 reports the columns the clause reads" do
      {:ok, compiled} = Eval.compile("id = 1 AND lower(name) = 'a'", %{})
      assert Enum.sort(Eval.columns(compiled)) == ["id", "name"]
    end

    test "a qualified column name resolves to the shape's one table" do
      {:ok, compiled} = Eval.compile("public.widgets.id = 7", %{})
      assert Eval.matches?(compiled, @row)
    end
  end
end
