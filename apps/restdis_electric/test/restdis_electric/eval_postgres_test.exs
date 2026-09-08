defmodule RestdisElectric.EvalPostgresTest do
  @moduledoc """
  The gate for the filter work: every expression in the supported subset must
  produce the same decision as Postgres evaluating the same expression.

  A difference here is not only a correctness bug, it is a security bug — if we
  return true where Postgres returns false, a row reaches a client that must
  not see it. So this compares against a live Postgres rather than against our
  own idea of what Postgres does.
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  alias RestdisElectric.Eval

  @rows [
    %{
      "id" => 7,
      "name" => "Alice",
      "email" => nil,
      "score" => 4.5,
      "active" => true,
      "tags" => ["red", "blue"]
    },
    %{
      "id" => -3,
      "name" => "bob",
      "email" => "bob@example.com",
      "score" => -0.5,
      "active" => false,
      "tags" => []
    },
    %{
      "id" => 0,
      "name" => "%_odd",
      "email" => nil,
      "score" => 0.0,
      "active" => nil,
      "tags" => ["green"]
    },
    %{
      "id" => 12,
      "name" => "ALICE",
      "email" => "a@b.c",
      "score" => 100.25,
      "active" => true,
      "tags" => ["red", "green", "blue"]
    }
  ]

  setup_all do
    opts = [
      hostname: System.get_env("RESTDIS_POSTGRES_HOSTNAME", "localhost"),
      username: "postgres",
      password: "postgres",
      database: "restdis_test"
    ]

    {:ok, conn} = Postgrex.start_link(opts)
    %{conn: conn}
  end

  # -- generators -------------------------------------------------------------

  defp int_literal, do: map(integer(-20..20), &Integer.to_string/1)
  defp nonzero_literal, do: map(integer(1..9), &Integer.to_string/1)

  defp int_term do
    one_of([
      constant("id"),
      int_literal(),
      map({int_literal(), member_of(["+", "-", "*"])}, fn {n, op} -> "id #{op} #{n}" end),
      map(nonzero_literal(), &"id / #{&1}"),
      map(nonzero_literal(), &"id % #{&1}"),
      map({member_of(["&", "|", "#"]), int_literal()}, fn {op, n} -> "id #{op} #{n}" end),
      map(integer(0..4), &"id << #{&1}"),
      map(integer(0..4), &"id >> #{&1}"),
      map(int_literal(), &"greatest(id, #{&1})"),
      map(int_literal(), &"least(id, #{&1})"),
      map(int_literal(), &"coalesce(id, #{&1})")
    ])
  end

  defp text_literal, do: map(member_of(~w(Alice alice bob %_odd x)), &"'#{&1}'")

  defp text_term do
    one_of([
      constant("name"),
      constant("email"),
      text_literal(),
      constant("lower(name)"),
      constant("upper(name)"),
      constant("coalesce(email, name)"),
      constant("greatest(email, name)"),
      constant("least(email, name)")
    ])
  end

  defp comparison_op, do: member_of(~w(= <> < <= > >=))

  defp boolean_term do
    one_of([
      constant("active"),
      map({int_term(), comparison_op(), int_term()}, fn {l, op, r} -> "#{l} #{op} #{r}" end),
      map({text_term(), comparison_op(), text_term()}, fn {l, op, r} -> "#{l} #{op} #{r}" end)
    ])
  end

  defp array_literal do
    map(list_of(member_of(~w(red blue green)), min_length: 1, max_length: 3), fn items ->
      "ARRAY[" <> Enum.map_join(items, ", ", &"'#{&1}'") <> "]"
    end)
  end

  defp atom_predicate do
    one_of([
      map({int_term(), comparison_op(), int_term()}, fn {l, op, r} -> "#{l} #{op} #{r}" end),
      map({text_term(), comparison_op(), text_term()}, fn {l, op, r} -> "#{l} #{op} #{r}" end),
      map(
        {text_term(), member_of(["LIKE", "NOT LIKE", "ILIKE", "NOT ILIKE"]),
         member_of(~w(a% %ice A_ice %_% bob _ %))},
        fn {t, op, pattern} -> "#{t} #{op} '#{pattern}'" end
      ),
      map({member_of(["@>", "<@", "&&"]), array_literal()}, fn {op, arr} ->
        "tags #{op} #{arr}"
      end),
      map(
        {one_of([int_term(), text_term(), constant("active")]),
         member_of(["IS NULL", "IS NOT NULL"])},
        fn {t, test} -> "#{t} #{test}" end
      ),
      # Postgres restricts the boolean tests to boolean arguments, so only boolean-valued terms are generated for them.
      map(
        {boolean_term(),
         member_of([
           "IS TRUE",
           "IS NOT TRUE",
           "IS FALSE",
           "IS NOT FALSE",
           "IS UNKNOWN",
           "IS NOT UNKNOWN"
         ])},
        fn {t, test} -> "(#{t}) #{test}" end
      ),
      map(
        {int_term(), member_of(["IN", "NOT IN"]),
         list_of(int_literal(), min_length: 1, max_length: 3)},
        fn {t, op, items} -> "#{t} #{op} (#{Enum.join(items, ", ")})" end
      ),
      map(
        {int_term(), member_of(["BETWEEN", "NOT BETWEEN"]), int_literal(), int_literal()},
        fn {t, op, low, high} -> "#{t} #{op} #{low} AND #{high}" end
      ),
      map(
        {int_term(), comparison_op(), member_of(["ANY", "ALL"]),
         list_of(int_literal(), min_length: 1, max_length: 3)},
        fn {t, op, quant, items} -> "#{t} #{op} #{quant}(ARRAY[#{Enum.join(items, ", ")}])" end
      ),
      map({text_literal(), member_of(["ANY", "ALL"])}, fn {lit, quant} ->
        "#{lit} = #{quant}(tags)"
      end),
      constant("active"),
      constant("NOT active")
    ])
  end

  defp predicate do
    tree(atom_predicate(), fn child ->
      one_of([
        map({child, member_of(["AND", "OR"]), child}, fn {l, op, r} -> "(#{l}) #{op} (#{r})" end),
        map(child, &"NOT (#{&1})")
      ])
    end)
  end

  # -- the comparison ---------------------------------------------------------

  @tag timeout: 300_000
  property "every supported expression decides the same way as Postgres", %{conn: conn} do
    check all(where <- predicate(), max_runs: 300) do
      assert {:ok, compiled} = Eval.compile(where, %{})

      for row <- @rows do
        assert Eval.matches?(compiled, row) == postgres_matches?(conn, where, row),
               """
               where:    #{where}
               row:      #{inspect(row)}
               restdis:  #{inspect(Eval.matches?(compiled, row))}
               postgres: #{inspect(postgres_matches?(conn, where, row))}
               """
      end
    end
  end

  test "a hand-written set of tricky expressions agrees with Postgres", %{conn: conn} do
    expressions = [
      "id / 2 = 3",
      "id % 2 = 1",
      "-7 / 2 = -3",
      "-7 % 2 = -1",
      "id & 1 = 1",
      "id # 1 > 0",
      "name LIKE '\\%%'",
      "name ILIKE '%ICE'",
      "email IS NULL AND id > 0",
      "(email = 'x') IS UNKNOWN",
      "id NOT IN (1, 2)",
      "tags @> ARRAY['red'] AND tags && ARRAY['blue']",
      "'red' = ANY(tags)",
      "'red' <> ALL(tags)",
      "greatest(email, name) = 'Alice'",
      "coalesce(email, name, 'z') = 'Alice'",
      "least(id, 0, 5) = 0",
      "NOT (id = 7 AND email IS NOT NULL)"
    ]

    for where <- expressions, row <- @rows do
      assert {:ok, compiled} = Eval.compile(where, %{})

      assert Eval.matches?(compiled, row) == postgres_matches?(conn, where, row),
             "#{where} over #{inspect(row)}"
    end
  end

  defp postgres_matches?(conn, where, row) do
    sql = "SELECT (#{where}) IS TRUE FROM (SELECT #{row_literal(row)}) t"
    %Postgrex.Result{rows: [[result]]} = Postgrex.query!(conn, sql, [])
    result
  end

  defp row_literal(row) do
    Enum.map_join(
      [
        {"id", "int", row["id"]},
        {"name", "text", row["name"]},
        {"email", "text", row["email"]},
        {"score", "float8", row["score"]},
        {"active", "boolean", row["active"]},
        {"tags", "text[]", row["tags"]}
      ],
      ", ",
      fn {name, type, value} -> "#{sql_literal(value)}::#{type} AS #{name}" end
    )
  end

  defp sql_literal(nil), do: "NULL"
  defp sql_literal(value) when is_number(value) or is_boolean(value), do: "#{value}"

  defp sql_literal(value) when is_binary(value),
    do: "'" <> String.replace(value, "'", "''") <> "'"

  defp sql_literal(values) when is_list(values),
    do: "ARRAY[" <> Enum.map_join(values, ", ", &sql_literal/1) <> "]::text[]"
end
