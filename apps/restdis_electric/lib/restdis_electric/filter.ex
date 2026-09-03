defmodule RestdisElectric.Filter do
  @moduledoc """
  A hash index from `(table, column, constant)` to the shapes whose filter can
  match a row carrying that constant.

  Testing every shape's `where` clause against every WAL change costs time in
  proportion to the number of shapes. This index removes that: for the clause
  forms `field = constant`, `constant = field`, `field IN (list)`,
  `array_field @> constant` and `constant = ANY(array_field)`, including
  combinations joined by `AND` and `OR`, a change only reaches the shapes that
  the row's own values point at.

  Two properties make it safe.

  1. The index is a *necessary* condition, never a sufficient one. A shape it
     returns is still evaluated in full by `RestdisElectric.Eval`, so a false
     positive costs one evaluation and nothing else.
  2. A shape whose clause has no indexable part joins the unindexed set for its
     table and is tested for every change. Correctness never depends on the
     index; only throughput does.

  Constants are normalised the same way on both sides — the same coercion
  `RestdisElectric.Eval` applies when it compares text against a number — so
  the index can never miss a shape that the evaluator would have matched.
  """

  use GenServer

  alias RestdisElectric.Definition
  alias RestdisElectric.Eval

  @index __MODULE__.Index
  @columns __MODULE__.Columns
  @unindexed __MODULE__.Unindexed
  @registered __MODULE__.Registered

  @tables [@index, @columns, @unindexed, @registered]

  @doc """
  Starts the index's ETS tables.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Indexes `handle`'s shape. Replaces any previous entry for the same handle,
  so re-subscribing to a shape does not duplicate its index entries.
  """
  @spec add(String.t(), Definition.t(), String.t()) :: :ok
  def add(tenant_id, %Definition{} = definition, handle) do
    if ready?() do
      remove(tenant_id, handle)
      do_add(tenant_id, definition, handle)
    end

    :ok
  end

  @doc """
  Removes every index entry for `handle`.
  """
  @spec remove(String.t(), String.t()) :: :ok
  def remove(tenant_id, handle) do
    if ready?() do
      @registered
      |> :ets.lookup({tenant_id, handle})
      |> Enum.each(fn {_key, entry} -> :ets.delete_object(table_of(entry), entry) end)

      :ets.delete(@registered, {tenant_id, handle})
    end

    :ok
  end

  @doc """
  Returns the handles whose shapes may match any of `rows`, which are the
  pre-image and post-image of one change.

  Emits `[:restdis_electric, :filter, :lookup]` with the number of shapes the
  index answered with, the number that had to be tested unconditionally, and
  how many are registered on the table in total.
  """
  @spec candidates(String.t(), String.t(), String.t(), [map() | nil]) :: [String.t()]
  def candidates(tenant_id, schema, table, rows) do
    if ready?() do
      key = {tenant_id, schema, table}
      rows = Enum.reject(rows, &is_nil/1)

      indexed = MapSet.new(indexed_handles(key, rows))
      unindexed = MapSet.new(@unindexed |> :ets.lookup(key) |> Enum.map(&elem(&1, 1)))
      candidates = MapSet.union(indexed, unindexed)

      :telemetry.execute(
        [:restdis_electric, :filter, :lookup],
        %{
          indexed: MapSet.size(indexed),
          unindexed: MapSet.size(unindexed),
          candidates: MapSet.size(candidates)
        },
        %{tenant_id: tenant_id, schema: schema, table: table}
      )

      MapSet.to_list(candidates)
    else
      []
    end
  end

  @doc """
  Normalises a value into its index key form.

  Text that parses as a number normalises to that number's form, because
  `RestdisElectric.Eval` coerces text against a numeric column the same way.
  Values with no stable key form — `NULL` and arrays in a scalar position —
  return `:error`, and the shape falls back to the unindexed set.
  """
  @spec normalise(term()) :: {:ok, String.t()} | :error
  def normalise(nil), do: :error
  def normalise(:null), do: :error
  def normalise(true), do: {:ok, "b:true"}
  def normalise(false), do: {:ok, "b:false"}
  def normalise(value) when is_integer(value), do: {:ok, "n:#{value}"}

  def normalise(value) when is_float(value) do
    if value == trunc(value) and abs(value) < 1.0e15 do
      {:ok, "n:#{trunc(value)}"}
    else
      {:ok, "n:#{value}"}
    end
  end

  def normalise(value) when is_binary(value) do
    case numeric(value) do
      {:ok, number} -> normalise(number)
      :error -> {:ok, "s:#{value}"}
    end
  end

  def normalise(_value), do: :error

  defp numeric(text) do
    case Integer.parse(text) do
      {integer, ""} -> {:ok, integer}
      _ -> float(text)
    end
  end

  defp float(text) do
    case Float.parse(text) do
      {number, ""} -> {:ok, number}
      _ -> :error
    end
  end

  # -- index construction -----------------------------------------------------

  defp do_add(tenant_id, definition, handle) do
    key = {tenant_id, definition.schema, definition.table}

    case index_keys(definition.filter) do
      {:indexed, keys} -> Enum.each(keys, &insert(key, &1, tenant_id, handle))
      :unindexed -> insert_unindexed(key, tenant_id, handle)
    end
  end

  defp insert(key, {kind, column, value}, tenant_id, handle) do
    {tenant, schema, table} = key
    entry = {{tenant, schema, table, kind, column, value}, handle}
    :ets.insert(@index, entry)
    :ets.insert(@columns, {{tenant, schema, table, kind}, column})
    :ets.insert(@registered, {{tenant_id, handle}, entry})
  end

  defp insert_unindexed(key, tenant_id, handle) do
    entry = {key, handle}
    :ets.insert(@unindexed, entry)
    :ets.insert(@registered, {{tenant_id, handle}, entry})
  end

  defp table_of({{_tenant, _schema, _table}, _handle}), do: @unindexed
  defp table_of(_entry), do: @index

  @doc """
  Returns the index keys a compiled filter can be indexed under, or
  `:unindexed`.

  Each returned key is a necessary condition on its own: a matching row must
  carry at least one of them. `OR` contributes every branch's keys, because a
  row may satisfy either; `AND` contributes one branch's keys, because a row
  must satisfy both, so either branch alone narrows the candidates correctly.
  """
  @spec index_keys(Eval.t() | nil) ::
          {:indexed, [{:scalar | :array, String.t(), String.t()}]} | :unindexed
  def index_keys(nil), do: :unindexed
  def index_keys(%Eval{tree: tree, params: params}), do: keys(tree, params)

  defp keys({:binop, "OR", left, right}, params) do
    case {keys(left, params), keys(right, params)} do
      {{:indexed, left_keys}, {:indexed, right_keys}} -> {:indexed, left_keys ++ right_keys}
      _ -> :unindexed
    end
  end

  defp keys({:binop, "AND", left, right}, params) do
    case keys(left, params) do
      {:indexed, _} = indexed -> indexed
      :unindexed -> keys(right, params)
    end
  end

  defp keys({:binop, "=", {:ident, column}, other}, params),
    do: scalar_key(column, other, params)

  defp keys({:binop, "=", other, {:ident, column}}, params),
    do: scalar_key(column, other, params)

  defp keys({:binop, "@>", {:ident, column}, {:array, items}}, params) do
    case constants(items, params) do
      {:ok, [_ | _] = values} -> array_keys(column, values)
      _ -> :unindexed
    end
  end

  defp keys({:any, "=", other, {:ident, column}}, params) do
    case constant(other, params) do
      {:ok, value} -> array_keys(column, [value])
      :error -> :unindexed
    end
  end

  defp keys({:in_list, {:ident, column}, items, false}, params) do
    case constants(items, params) do
      {:ok, [_ | _] = values} -> scalar_keys(column, values)
      _ -> :unindexed
    end
  end

  defp keys(_tree, _params), do: :unindexed

  defp scalar_key(column, other, params) do
    case constant(other, params) do
      {:ok, value} -> scalar_keys(column, [value])
      :error -> :unindexed
    end
  end

  # `x IN (1, 2)` is a disjunction, each value its own key. One unindexable value makes the whole clause unindexable.
  defp scalar_keys(column, values), do: build_keys(:scalar, column, values)

  # `tags @> ARRAY[a, b]` is a conjunction, so any one value narrows correctly.
  defp array_keys(column, values), do: build_keys(:array, column, values)

  defp build_keys(kind, column, values) do
    normalised = Enum.map(values, &normalise/1)

    if Enum.all?(normalised, &match?({:ok, _}, &1)) do
      {:indexed, Enum.map(normalised, fn {:ok, value} -> {kind, name(column), value} end)}
    else
      :unindexed
    end
  end

  defp name(column), do: column |> String.split(".") |> List.last()

  defp constants(items, params) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case constant(item, params) do
        {:ok, value} -> {:cont, {:ok, acc ++ [value]}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp constant({:lit, {:number, text}}, _params), do: {:ok, text}
  defp constant({:lit, {:string, text}}, _params), do: {:ok, text}
  defp constant({:lit, {:bool, bool}}, _params), do: {:ok, bool}
  defp constant({:param, index}, params), do: Map.fetch(params, index)
  defp constant(_node, _params), do: :error

  # -- lookup -----------------------------------------------------------------

  defp indexed_handles({tenant, schema, table}, rows) do
    Enum.flat_map([:scalar, :array], fn kind ->
      @columns
      |> :ets.lookup({tenant, schema, table, kind})
      |> Enum.flat_map(&handles_for_column(&1, {tenant, schema, table}, kind, rows))
    end)
  end

  defp handles_for_column({_key, column}, {tenant, schema, table}, kind, rows) do
    rows
    |> Enum.flat_map(&values_for(kind, &1, column))
    |> Enum.flat_map(fn value ->
      @index
      |> :ets.lookup({tenant, schema, table, kind, column, value})
      |> Enum.map(&elem(&1, 1))
    end)
  end

  defp values_for(:scalar, row, column), do: normalised(Map.get(row, column))

  defp values_for(:array, row, column) do
    case Map.get(row, column) do
      list when is_list(list) -> Enum.flat_map(list, &normalised/1)
      _other -> []
    end
  end

  defp normalised(value) do
    case normalise(value) do
      {:ok, normalised} -> [normalised]
      :error -> []
    end
  end

  defp ready?, do: :ets.whereis(@index) != :undefined

  @impl GenServer
  def init(_opts) do
    Enum.each(@tables, fn table ->
      :ets.new(table, [:bag, :public, :named_table, read_concurrency: true])
    end)

    {:ok, %{}}
  end
end
