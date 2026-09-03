defmodule RestdisElectric.Eval do
  @moduledoc """
  Compiles and evaluates a `where` clause over exactly the subset Electric
  documents.

  Supported: the comparison, logical, arithmetic and bitwise operators;
  `LIKE` and `ILIKE`; the array operators `@>`, `<@` and `&&`; null and
  boolean tests; `IN` and `NOT IN`; `BETWEEN`; `ANY` and `ALL`; and the
  functions `lower`, `upper`, `coalesce`, `greatest` and `least`.

  Everything else — JSONB operators, full-text search, geometric and network
  types, range operators, casts, most subqueries, and functions whose result
  changes between calls such as `now()` — is rejected by `compile/2` with
  `{:error, {:unsupported_where, description}}`. Nothing outside the subset is
  ever silently accepted: accepting a shape and then filtering it incorrectly
  would send one tenant's rows to another.

  `field IN (SELECT column FROM table [WHERE ...])` parses and structurally
  validates (see `subqueries/1`), but deciding it from one row alone is
  impossible — the answer depends on a second table's current contents.
  `matches?/2` (no resolver) and `evaluate/2` treat it as `:null`, which is
  what every test that only cares about the rest of a clause gets.
  `matches?/3` accepts a `t:subquery_resolver/0` that decides it instead;
  `RestdisElectric.SubqueryTracker` supplies one backed by a live-maintained
  result set for the bare form `RestdisElectric.Definition` accepts (see
  `bare_subquery/1` and `RestdisElectric.SubqueryTracker`'s moduledoc for the
  scope: a subquery combined with `AND`/`OR` is still rejected, because that
  would require this module to also decide the surrounding clause against
  a partially-invalidated row, which it does not yet do).

  Values follow Postgres's three-valued logic. `:null` is SQL `NULL`, and a
  row matches only when the clause evaluates to exactly `true`, which is what
  Postgres's `WHERE` does.

  `$1` placeholders read from the `params` map given to `compile/2`. Values
  are never interpolated into the expression text.

  ## Text ordering

  `<`, `<=`, `>`, and `>=` on text compare with Elixir's byte-order `<`/`>`,
  which matches a Postgres database initialized with the `C` collation. A
  database using a linguistic collation (the default on many platform
  installs) may order punctuation and case differently and disagree with us.
  Tenants that need `<`/`>` on text must run their table under `C` collation,
  or restrict shapes to the other supported operators.
  """

  alias RestdisElectric.SqlParser

  @type value :: :null | boolean() | number() | String.t() | [value()]
  @type row :: %{optional(String.t()) => term()}

  @type t :: %__MODULE__{
          source: String.t(),
          tree: SqlParser.tree(),
          params: %{pos_integer() => String.t()},
          columns: [String.t()]
        }

  @type error :: {:unsupported_where, String.t()} | {:invalid_where, String.t()}

  @enforce_keys [:source, :tree, :params, :columns]
  defstruct [:source, :tree, :params, :columns]

  @comparison ~w(= <> != < <= > >=)
  @arithmetic ~w(+ - * / %)
  @bitwise ~w(& | # << >>)
  @array_ops ~w(@> <@ &&)
  @logical ~w(AND OR)
  @functions ~w(lower upper coalesce greatest least)
  @is_tests ~w(is_null is_not_null is_true is_not_true is_false is_not_false is_unknown
               is_not_unknown)

  @doc """
  Parses and validates `where`, binding `$1` placeholders to `params`.

  `params` is keyed by placeholder number, as either an integer or the string
  form the query string carries (`params[1]=x`).
  """
  @spec compile(String.t(), map()) :: {:ok, t()} | {:error, error()}
  def compile(where, params \\ %{}) when is_binary(where) do
    with {:ok, tree} <- parse(where),
         {:ok, bound} <- normalise_params(params),
         :ok <- check(tree, bound) do
      {:ok,
       %__MODULE__{source: where, tree: tree, params: bound, columns: collect_columns(tree, [])}}
    end
  end

  @typedoc """
  Decides whether `value` (the outer row's value of the `IN`'s left-hand
  expression) is currently a member of a `field IN (subquery)` clause's live
  result set. `table` and `column` identify the subquery, as returned by
  `subqueries/1`. Used by `RestdisElectric.SubqueryTracker` to make
  `matches?/3` actually decide a bare subquery clause instead of treating it
  as `:null`; see its moduledoc for the scope this supports.
  """
  @type subquery_resolver ::
          (table :: String.t(), column :: String.t(), value :: value() -> boolean() | :null)

  @doc """
  Returns true when `row` satisfies the compiled clause.

  A `nil` clause matches every row, which is what a shape with no `where`
  parameter means. A `nil` row never matches: it is the missing pre-image of
  an insert or the missing post-image of a delete.

  `resolver`, if given, decides any `field IN (subquery)` node the clause
  contains (see `t:subquery_resolver/0`); without one such a node is always
  `:null`, per this module's moduledoc.
  """
  @spec matches?(t() | nil, row() | nil, subquery_resolver() | nil) :: boolean()
  def matches?(compiled, row, resolver \\ nil)
  def matches?(nil, nil, _resolver), do: false
  def matches?(nil, _row, _resolver), do: true
  def matches?(%__MODULE__{}, nil, _resolver), do: false

  def matches?(%__MODULE__{} = compiled, row, resolver) when is_map(row) do
    eval(compiled.tree, row, with_resolver(compiled.params, resolver)) == true
  end

  # `resolver` rides in the `params` map every `eval` clause threads through, under a key no placeholder collides with.
  defp with_resolver(params, nil), do: params
  defp with_resolver(params, resolver), do: Map.put(params, :subquery_resolver, resolver)

  @doc """
  If `filter`'s entire clause is exactly one `column IN (subquery)` (or
  `NOT IN`) node — no `AND`/`OR` combination with anything else — returns its
  pieces. Anything else, including a subquery inside a larger clause,
  returns `:error`. `RestdisElectric.Definition.check_subqueries/3` only
  accepts a subquery in this bare form (see `RestdisElectric.SubqueryTracker`
  for why), so this is the single source of truth both use for "is this
  shape's live subquery tracking supported".
  """
  @spec bare_subquery(t() | nil) ::
          {:ok,
           %{
             column: String.t(),
             table: String.t(),
             inner_column: String.t(),
             selection: SqlParser.tree() | :none,
             negated: boolean()
           }}
          | :error
  def bare_subquery(%__MODULE__{
        tree: {:in_subquery, {:ident, column}, negated, table, inner_column, selection}
      }) do
    {:ok,
     %{
       column: column,
       table: table,
       inner_column: inner_column,
       selection: selection,
       negated: negated
     }}
  end

  def bare_subquery(_filter), do: :error

  @doc """
  Returns the column names the clause references.
  """
  @spec columns(t() | nil) :: [String.t()]
  def columns(nil), do: []
  def columns(%__MODULE__{columns: columns}), do: columns

  @typedoc """
  One `field IN (SELECT column FROM table [WHERE ...])` clause: the
  subquery's table (as written, possibly `schema.table`), its one projected
  column, and its own `WHERE` clause's parse tree, or `:none` if it has none.
  """
  @type subquery :: {table :: String.t(), column :: String.t(), SqlParser.tree() | :none}

  @doc """
  Returns every `field IN (subquery)` clause the compiled filter contains,
  including ones nested inside `AND`, `OR`, and `NOT`.

  This does not decide whether a subquery is correlated to the shape's own
  table; that needs the two tables' real schemas, which only
  `RestdisElectric.Definition` has.
  """
  @spec subqueries(t() | nil) :: [subquery()]
  def subqueries(nil), do: []
  def subqueries(%__MODULE__{tree: tree}), do: collect_subqueries(tree, [])

  defp collect_subqueries({:in_subquery, _expr, _negated, table, column, selection}, acc),
    do: [{table, column, selection} | acc]

  defp collect_subqueries(node, acc) when is_tuple(node) do
    node |> Tuple.to_list() |> Enum.reduce(acc, &collect_subqueries/2)
  end

  defp collect_subqueries(nodes, acc) when is_list(nodes),
    do: Enum.reduce(nodes, acc, &collect_subqueries/2)

  defp collect_subqueries(_other, acc), do: acc

  @doc """
  Returns the column names a raw parse tree references, the same rule
  `columns/1` applies to a compiled filter's own table. Used to validate a
  subquery's `WHERE` clause against its own table's schema.
  """
  @spec tree_columns(SqlParser.tree() | :none) :: [String.t()]
  def tree_columns(:none), do: []
  def tree_columns(tree), do: tree |> collect_columns([]) |> Enum.uniq()

  # -- parsing and validation -------------------------------------------------

  defp parse(where) do
    case SqlParser.parse(where) do
      {:ok, tree} -> {:ok, tree}
      {:error, message} -> {:error, {:invalid_where, message}}
    end
  end

  defp normalise_params(params) when is_map(params) do
    Enum.reduce_while(params, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case normalise_param_key(key) do
        {:ok, index} -> {:cont, {:ok, Map.put(acc, index, value)}}
        :error -> {:halt, {:error, {:invalid_where, "invalid parameter name #{inspect(key)}"}}}
      end
    end)
  end

  defp normalise_params(_params), do: {:error, {:invalid_where, "'params' must be a map"}}

  defp normalise_param_key(key) when is_integer(key) and key > 0, do: {:ok, key}

  defp normalise_param_key(key) when is_binary(key) do
    case Integer.parse(key) do
      {index, ""} when index > 0 -> {:ok, index}
      _ -> :error
    end
  end

  defp normalise_param_key(_key), do: :error

  defp check({:unsupported, description}, _params),
    do: {:error, {:unsupported_where, description}}

  defp check({:ident, _name}, _params), do: :ok
  defp check({:lit, _value}, _params), do: :ok

  defp check({:param, index}, params) do
    if Map.has_key?(params, index) do
      :ok
    else
      {:error, {:invalid_where, "no value supplied for placeholder $#{index}"}}
    end
  end

  defp check({:binop, op, left, right}, params) when op in @array_ops do
    # Postgres reads `@>`/`<@`/`&&` over ranges too; requiring an array literal operand keeps us to the array reading.
    if match?({:array, _}, left) or match?({:array, _}, right) do
      check_all([left, right], params)
    else
      {:error, {:unsupported_where, "operator #{op} without an array literal operand"}}
    end
  end

  defp check({:binop, op, left, right}, params) do
    if op in @comparison or op in @arithmetic or op in @bitwise or op in @array_ops or
         op in @logical do
      check_all([left, right], params)
    else
      {:error, {:unsupported_where, "operator #{op}"}}
    end
  end

  defp check({:unop, op, expr}, params) when op in ["NOT", "-", "+"], do: check(expr, params)
  defp check({:unop, op, _expr}, _params), do: {:error, {:unsupported_where, "operator #{op}"}}

  defp check({:is, test, expr}, params) when test in @is_tests, do: check(expr, params)

  defp check({:in_list, expr, items, _negated}, params), do: check_all([expr | items], params)

  defp check({:between, expr, low, high, _negated}, params),
    do: check_all([expr, low, high], params)

  defp check({:like, expr, pattern, _negated, _ci}, params),
    do: check_all([expr, pattern], params)

  defp check({kind, op, left, right}, params) when kind in [:any, :all] do
    if op in @comparison do
      check_all([left, right], params)
    else
      {:error, {:unsupported_where, "operator #{op} with #{String.upcase(to_string(kind))}"}}
    end
  end

  defp check({:func, name, args}, params) do
    if name in @functions do
      check_all(args, params)
    else
      {:error, {:unsupported_where, "function #{name}()"}}
    end
  end

  defp check({:array, items}, params), do: check_all(items, params)

  defp check({:in_subquery, expr, negated, _table, _column, selection}, params)
       when is_boolean(negated) do
    with :ok <- check(expr, params) do
      check_selection(selection, params)
    end
  end

  defp check(other, _params), do: {:error, {:unsupported_where, inspect(other)}}

  defp check_selection(:none, _params), do: :ok
  defp check_selection(selection, params), do: check(selection, params)

  defp check_all(nodes, params) do
    Enum.reduce_while(nodes, :ok, fn node, :ok ->
      case check(node, params) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp collect_columns({:ident, name}, acc), do: [name | acc]

  # A subquery's columns belong to a second table, validated separately by `RestdisElectric.Definition`.
  defp collect_columns({:in_subquery, expr, _negated, _table, _column, _selection}, acc),
    do: collect_columns(expr, acc)

  defp collect_columns(node, acc) when is_tuple(node) do
    node |> Tuple.to_list() |> Enum.reduce(acc, &collect_columns/2)
  end

  defp collect_columns(nodes, acc) when is_list(nodes),
    do: Enum.reduce(nodes, acc, &collect_columns/2)

  defp collect_columns(_other, acc), do: acc

  # -- evaluation -------------------------------------------------------------

  @doc """
  Evaluates the compiled clause against `row` and returns the SQL value,
  which may be `:null`.
  """
  @spec evaluate(t(), row()) :: value()
  def evaluate(%__MODULE__{} = compiled, row), do: eval(compiled.tree, row, compiled.params)

  defp eval({:ident, name}, row, _params), do: fetch_column(row, name)
  defp eval({:lit, literal}, _row, _params), do: literal_value(literal)
  defp eval({:param, index}, _row, params), do: param_value(Map.get(params, index))

  defp eval({:binop, "AND", left, right}, row, params),
    do: and_(eval(left, row, params), eval(right, row, params))

  defp eval({:binop, "OR", left, right}, row, params),
    do: or_(eval(left, row, params), eval(right, row, params))

  defp eval({:binop, op, left, right}, row, params),
    do: binop(op, eval(left, row, params), eval(right, row, params))

  defp eval({:unop, "NOT", expr}, row, params), do: not_(eval(expr, row, params))
  defp eval({:unop, "+", expr}, row, params), do: eval(expr, row, params)

  defp eval({:unop, "-", expr}, row, params) do
    case eval(expr, row, params) do
      n when is_number(n) -> -n
      _ -> :null
    end
  end

  defp eval({:is, test, expr}, row, params), do: sql_test(test, eval(expr, row, params))

  defp eval({:in_list, expr, items, negated}, row, params) do
    value = eval(expr, row, params)
    candidates = Enum.map(items, &eval(&1, row, params))
    result = any_of("=", value, candidates)
    if negated, do: not_(result), else: result
  end

  defp eval({:between, expr, low, high, negated}, row, params) do
    value = eval(expr, row, params)

    result =
      and_(
        binop(">=", value, eval(low, row, params)),
        binop("<=", value, eval(high, row, params))
      )

    if negated, do: not_(result), else: result
  end

  defp eval({:like, expr, pattern, negated, case_insensitive}, row, params) do
    result = like(eval(expr, row, params), eval(pattern, row, params), case_insensitive)
    if negated, do: not_(result), else: result
  end

  defp eval({:any, op, left, right}, row, params) do
    case eval(right, row, params) do
      items when is_list(items) -> any_of(op, eval(left, row, params), items)
      _ -> :null
    end
  end

  defp eval({:all, op, left, right}, row, params) do
    case eval(right, row, params) do
      items when is_list(items) -> all_of(op, eval(left, row, params), items)
      _ -> :null
    end
  end

  defp eval({:array, items}, row, params), do: Enum.map(items, &eval(&1, row, params))

  defp eval({:func, name, args}, row, params),
    do: call(name, Enum.map(args, &eval(&1, row, params)))

  defp eval({:in_subquery, expr, negated, table, column, _selection}, row, params) do
    case Map.get(params, :subquery_resolver) do
      nil -> :null
      resolver -> resolved_member({table, column, eval(expr, row, params)}, resolver, negated)
    end
  end

  defp eval(_other, _row, _params), do: :null

  defp resolved_member({table, column, value}, resolver, negated) do
    case resolver.(table, column, value) do
      :null -> :null
      member? when is_boolean(member?) -> if negated, do: not member?, else: member?
    end
  end

  defp fetch_column(row, name) do
    case Map.fetch(row, name) do
      {:ok, value} -> to_value(value)
      :error -> fetch_unqualified(row, name)
    end
  end

  # `schema.table.column` and `table.column` both address a column of the one table a shape reads, so the last segment is enough to find it.
  defp fetch_unqualified(row, name) do
    case String.split(name, ".") do
      [_single] -> :null
      parts -> to_value(Map.get(row, List.last(parts)))
    end
  end

  defp to_value(nil), do: :null
  defp to_value(value) when is_list(value), do: Enum.map(value, &to_value/1)
  defp to_value(value), do: value

  defp literal_value({:number, text}), do: parse_number(text)
  defp literal_value({:string, text}), do: text
  defp literal_value({:bool_, bool}), do: bool
  defp literal_value(:null), do: :null

  defp param_value(nil), do: :null
  defp param_value(value), do: value

  defp parse_number(text) do
    case Integer.parse(text) do
      {integer, ""} -> integer
      _ -> parse_float(text)
    end
  end

  defp parse_float(text) do
    case Float.parse(text) do
      {float, ""} -> float
      _ -> :null
    end
  end

  # -- operators --------------------------------------------------------------

  defp and_(false, _), do: false
  defp and_(_, false), do: false
  defp and_(true, true), do: true
  defp and_(_, _), do: :null

  defp or_(true, _), do: true
  defp or_(_, true), do: true
  defp or_(false, false), do: false
  defp or_(_, _), do: :null

  defp not_(true), do: false
  defp not_(false), do: true
  defp not_(_), do: :null

  defp sql_test("is_null", :null), do: true
  defp sql_test("is_null", _), do: false
  defp sql_test("is_not_null", :null), do: false
  defp sql_test("is_not_null", _), do: true
  defp sql_test("is_true", value), do: value == true
  defp sql_test("is_not_true", value), do: value != true
  defp sql_test("is_false", value), do: value == false
  defp sql_test("is_not_false", value), do: value != false
  defp sql_test("is_unknown", value), do: value == :null
  defp sql_test("is_not_unknown", value), do: value != :null

  defp binop(_op, :null, _right), do: :null
  defp binop(_op, _left, :null), do: :null

  defp binop(op, left, right) when op in @comparison do
    case compare(left, right) do
      :error -> :null
      order -> compare_result(op, order)
    end
  end

  defp binop(op, left, right) when op in @arithmetic, do: arithmetic(op, left, right)
  defp binop(op, left, right) when op in @bitwise, do: bitwise(op, left, right)
  defp binop(op, left, right) when op in @array_ops, do: array_op(op, left, right)
  defp binop(_op, _left, _right), do: :null

  defp compare_result("=", order), do: order == :eq
  defp compare_result("<>", order), do: order != :eq
  defp compare_result("!=", order), do: order != :eq
  defp compare_result("<", order), do: order == :lt
  defp compare_result("<=", order), do: order != :gt
  defp compare_result(">", order), do: order == :gt
  defp compare_result(">=", order), do: order != :lt

  @doc false
  @spec compare(value(), value()) :: :lt | :eq | :gt | :error
  def compare(left, right) when is_number(left) and is_number(right), do: order(left, right)
  def compare(left, right) when is_binary(left) and is_binary(right), do: order(left, right)
  def compare(left, right) when is_boolean(left) and is_boolean(right), do: order(left, right)

  # A `$1` placeholder and a query-string constant arrive as text, so a numeric comparison coerces it, as Postgres does.
  def compare(left, right) when is_binary(left) and is_number(right),
    do: coerced(parse_number(left), right)

  def compare(left, right) when is_number(left) and is_binary(right),
    do: coerced(left, parse_number(right))

  def compare(left, right) when is_binary(left) and is_boolean(right),
    do: coerced(parse_bool(left), right)

  def compare(left, right) when is_boolean(left) and is_binary(right),
    do: coerced(left, parse_bool(right))

  def compare(left, right) when is_list(left) and is_list(right), do: compare_lists(left, right)
  def compare(_left, _right), do: :error

  defp coerced(:null, _right), do: :error
  defp coerced(_left, :null), do: :error
  defp coerced(left, right), do: order(left, right)

  defp compare_lists([], []), do: :eq
  defp compare_lists([], _right), do: :lt
  defp compare_lists(_left, []), do: :gt

  defp compare_lists([left | lrest], [right | rrest]) do
    case compare(left, right) do
      :eq -> compare_lists(lrest, rrest)
      other -> other
    end
  end

  defp order(left, right) when left < right, do: :lt
  defp order(left, right) when left > right, do: :gt
  defp order(_left, _right), do: :eq

  defp parse_bool(text) do
    case String.downcase(String.trim(text)) do
      value when value in ["t", "true", "y", "yes", "on", "1"] -> true
      value when value in ["f", "false", "n", "no", "off", "0"] -> false
      _ -> :null
    end
  end

  defp arithmetic(op, left, right) when is_number(left) and is_number(right),
    do: do_arithmetic(op, left, right)

  defp arithmetic(_op, _left, _right), do: :null

  defp do_arithmetic("+", left, right), do: left + right
  defp do_arithmetic("-", left, right), do: left - right
  defp do_arithmetic("*", left, right), do: left * right
  defp do_arithmetic("/", _left, right) when right == 0, do: :null
  defp do_arithmetic("%", _left, right) when right == 0, do: :null

  # Postgres integer division truncates towards zero; float division does not.
  defp do_arithmetic("/", left, right) when is_integer(left) and is_integer(right),
    do: div(left, right)

  defp do_arithmetic("/", left, right), do: left / right

  defp do_arithmetic("%", left, right) when is_integer(left) and is_integer(right),
    do: rem(left, right)

  defp do_arithmetic("%", left, right), do: :math.fmod(left, right)

  defp bitwise(op, left, right) when is_integer(left) and is_integer(right),
    do: do_bitwise(op, left, right)

  defp bitwise(_op, _left, _right), do: :null

  defp do_bitwise("&", left, right), do: Bitwise.band(left, right)
  defp do_bitwise("|", left, right), do: Bitwise.bor(left, right)
  defp do_bitwise("#", left, right), do: Bitwise.bxor(left, right)
  defp do_bitwise("<<", left, right), do: Bitwise.bsl(left, right)
  defp do_bitwise(">>", left, right), do: Bitwise.bsr(left, right)

  defp array_op(op, left, right) when is_list(left) and is_list(right),
    do: do_array_op(op, left, right)

  defp array_op(_op, _left, _right), do: :null

  defp do_array_op("@>", left, right), do: Enum.all?(right, &member?(left, &1))
  defp do_array_op("<@", left, right), do: Enum.all?(left, &member?(right, &1))
  defp do_array_op("&&", left, right), do: Enum.any?(right, &member?(left, &1))

  defp member?(list, value), do: Enum.any?(list, &(compare(&1, value) == :eq))

  defp any_of(_op, :null, _items), do: :null
  defp any_of(op, value, items), do: quantify(op, value, items, true)

  defp all_of(_op, :null, _items), do: :null
  defp all_of(op, value, items), do: quantify(op, value, items, false)

  # `ANY` looks for one `true`, `ALL` one `false`; an unresolved `NULL` among the rest makes it unknown.
  defp quantify(op, value, items, target) do
    results = Enum.map(items, &binop(op, value, &1))

    cond do
      Enum.any?(results, &(&1 == target)) -> target
      Enum.any?(results, &(&1 == :null)) -> :null
      true -> not target
    end
  end

  defp like(:null, _pattern, _ci), do: :null
  defp like(_value, :null, _ci), do: :null

  defp like(value, pattern, case_insensitive) when is_binary(value) and is_binary(pattern) do
    opts = if case_insensitive, do: [:caseless], else: []

    case Regex.compile("\\A" <> like_to_regex(pattern) <> "\\z", opts) do
      {:ok, regex} -> Regex.match?(regex, value)
      {:error, _} -> :null
    end
  end

  defp like(_value, _pattern, _ci), do: :null

  defp like_to_regex(pattern), do: like_to_regex(String.graphemes(pattern), [])

  defp like_to_regex([], acc), do: acc |> Enum.reverse() |> Enum.join()

  defp like_to_regex(["\\", char | rest], acc),
    do: like_to_regex(rest, [Regex.escape(char) | acc])

  defp like_to_regex(["%" | rest], acc), do: like_to_regex(rest, ["(?s:.)*" | acc])
  defp like_to_regex(["_" | rest], acc), do: like_to_regex(rest, ["(?s:.)" | acc])
  defp like_to_regex([char | rest], acc), do: like_to_regex(rest, [Regex.escape(char) | acc])

  defp call("lower", [value]), do: map_string(value, &String.downcase/1)
  defp call("upper", [value]), do: map_string(value, &String.upcase/1)
  defp call("coalesce", args), do: Enum.find(args, :null, &(&1 != :null))
  defp call("greatest", args), do: extreme(args, [:gt])
  defp call("least", args), do: extreme(args, [:lt])
  defp call(_name, _args), do: :null

  defp map_string(:null, _fun), do: :null
  defp map_string(value, fun) when is_binary(value), do: fun.(value)
  defp map_string(_value, _fun), do: :null

  # Postgres's `greatest`/`least` ignore NULL arguments entirely.
  defp extreme(args, keep) do
    args
    |> Enum.reject(&(&1 == :null))
    |> Enum.reduce(:null, fn
      value, :null -> value
      value, best -> if compare(value, best) in keep, do: value, else: best
    end)
  end
end
