defmodule RestdisElectric.SqlParser do
  @moduledoc """
  Parses a `where` clause into a parse tree, using
  [`datafusion-sqlparser-rs`](https://github.com/apache/datafusion-sqlparser-rs)
  through Rustler with its `PostgreSqlDialect`.

  We do not write our own parser. The Rust side is a translation layer only:
  it turns the parser's `Expr` into tagged Elixir tuples and marks anything it
  does not recognise as `{:unsupported, description}`. Deciding what we accept
  is `RestdisElectric.Eval`'s job, so the parser cannot widen the supported
  subset by accident.

  Parsing happens only when a client subscribes, never on the WAL hot path.
  The NIF runs on a dirty CPU scheduler and refuses inputs over 8 KiB, so a
  pathological expression cannot block a normal scheduler.

  ## The parse tree

      {:ident, "name"}
      {:lit, {:number, "1"}} | {:lit, {:string, "a"}} | {:lit, {:bool, true}} | {:lit, :null}
      {:param, 1}
      {:binop, "=", left, right}
      {:unop, "NOT", expr}
      {:is, "is_null", expr}
      {:in_list, expr, [item], negated?}
      {:between, expr, low, high, negated?}
      {:like, expr, pattern, negated?, case_insensitive?}
      {:any, "=", left, right} | {:all, "=", left, right}
      {:func, "lower", [arg]}
      {:array, [item]}
      {:unsupported, description}
  """

  use Rustler, otp_app: :restdis_electric, crate: "restdis_electric_sql"

  @typedoc "A node of the parse tree. See the module doc for the shapes it takes."
  @type tree :: tuple()

  @doc """
  Parses `where` and returns its parse tree, or the parser's own message when
  the expression does not parse.
  """
  @spec parse(String.t()) :: {:ok, tree()} | {:error, String.t()}
  def parse(where) when is_binary(where) do
    start = System.monotonic_time()
    result = parse_nif(where)

    :telemetry.execute(
      [:restdis_electric, :where, :parse],
      %{duration: System.monotonic_time() - start, bytes: byte_size(where)},
      %{result: elem(result, 0)}
    )

    result
  end

  @doc false
  @spec parse_nif(String.t()) :: {:ok, tree()} | {:error, String.t()}
  def parse_nif(_where), do: :erlang.nif_error(:nif_not_loaded)
end
