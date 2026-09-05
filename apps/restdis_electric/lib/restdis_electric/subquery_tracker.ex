defmodule RestdisElectric.SubqueryTracker do
  @moduledoc """
  Live-tracks a shape's `field IN (SELECT column FROM table WHERE ...)`
  clause and keeps the shape's log in sync as the subquery's own table
  changes — the missing half of `RestdisElectric.Eval`'s `:in_subquery` node
  and `RestdisElectric.Definition`'s `field IN (subquery)` section
  (ELECTRIC_PRD Phase 6 item 1).

  ## Scope

  A shape's *entire* filter must be exactly one bare `column IN (subquery)`
  (or `NOT IN`) clause, or that clause combined with exactly one
  subquery-free predicate over a top-level `AND` or `OR`, for this to track
  it — `RestdisElectric.Eval.combined_subquery/1` is the single gate both
  this module and `RestdisElectric.Definition.check_subqueries/3` use to
  decide that. Anything else (more than one subquery, or a subquery under a
  top-level `NOT` alongside another predicate) is still rejected at
  subscribe time.

  For the combined form, this module's tracked set is still exactly the
  subquery's own matching set, not the shape's — the "rest" predicate is
  evaluated separately (see `combinator_allows?/2`) against each row a
  membership flip could affect, since it needs no live tracking of its own:
  it depends only on the outer row, which every insert/update/delete
  already carries. `AND` means only rows where "rest" already holds can
  change when the subquery flips (if "rest" is false the whole clause stays
  false regardless); `OR` means only rows where "rest" does not hold can
  change (if "rest" is true the whole clause stays true regardless).

  ## Why it needs a direct Postgres pool

  Computing and re-deriving "every id currently in this subquery's result"
  needs to read every row of the *inner* table directly — PostgREST has no
  such query. `RestdisElectric.subscribe/3` requires
  `tenant_config.direct_pg_url` for a shape with a subquery clause, the same
  requirement `log=changes_only` already has for a different reason.

  ## How it works

  1. `register_shape/4`, called once per subscribe, reads every row of the
     subquery's table through `RestdisElectric.Snapshotter.DirectPostgres`
     and keeps the `MapSet` of `inner_column` values whose row satisfies the
     subquery's own `WHERE` — the live matching set — plus enough to repeat
     that computation incrementally.
  2. `RestdisElectric.WAL.ingest/1` calls `route_inner_change/4` for *every*
     change, not only changes to a table some shape reads directly: the
     inner table often has no shape of its own (in the PRD's example,
     nothing reads `parents` directly, only `children` filtered through it).
  3. When a change to the inner table flips one row's membership,
     `route_inner_change/4` updates the tracked set and, if it changed,
     looks up every outer-table row currently matching the flipped id
     (`field = id`, through the same direct pool) and appends an `insert`
     (id newly in) or `delete` (id newly out) for each to every shape
     tracking that subquery.
  4. `RestdisElectric.Eval.matches?/3`'s resolver, built by `resolver/2`,
     answers a live `:in_subquery` node from the same tracked set — used
     both for the initial snapshot (a client subscribing after the tracker
     already exists must see the same matching set as the log) and for a
     direct change to the outer table itself (inserting a new child row).
  """

  use GenServer

  alias RestdisElectric.Definition
  alias RestdisElectric.Eval
  alias RestdisElectric.Log
  alias RestdisElectric.Message
  alias RestdisElectric.Snapshotter.DirectPostgres
  alias RestdisElectric.TableInfo

  @sets __MODULE__.Sets
  @shapes __MODULE__.Shapes
  @index __MODULE__.Index

  @type shape_key :: {tenant_id :: String.t(), handle :: String.t()}

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers `handle`'s subquery clause, if `definition.filter` has one in a
  form `RestdisElectric.Eval.combined_subquery/1` accepts, and computes its
  initial matching set by reading the inner table directly. A no-op,
  returning `:ok`, for a definition with no subquery.

  Idempotent: calling it again for the same shape recomputes the matching
  set from scratch, which a client resuming after a node restart needs.
  """
  @spec register_shape(String.t(), map(), Definition.t(), String.t()) :: :ok | {:error, term()}
  def register_shape(tenant_id, tenant_config, %Definition{filter: filter} = definition, handle) do
    case Eval.combined_subquery(filter) do
      :error ->
        :ok

      {:ok, pieces} ->
        do_register({tenant_id, handle}, tenant_config, definition, pieces)
    end
  end

  defp do_register({tenant_id, handle}, tenant_config, definition, pieces) do
    {inner_schema, inner_table} = split_table(pieces.table)

    info = %{
      outer_column: pieces.column,
      negated: pieces.negated,
      combinator: pieces.combinator,
      rest_filter: build_rest_filter(pieces.rest, definition.filter.params),
      inner_schema: inner_schema,
      inner_table: inner_table,
      inner_column: pieces.inner_column,
      inner_filter: build_inner_filter(pieces.selection, definition.filter.params),
      definition: definition,
      tenant_config: tenant_config
    }

    with {:ok, matching} <- fetch_matching_set(info) do
      key = {tenant_id, handle}
      unregister_shape(tenant_id, handle)

      :ets.insert(@shapes, {key, info})
      :ets.insert(@sets, {key, matching})
      :ets.insert(@index, {{tenant_id, inner_schema, inner_table}, key})
      :ok
    end
  end

  @doc """
  Removes every trace of `handle`'s subquery tracking. A no-op if it had
  none.
  """
  @spec unregister_shape(String.t(), String.t()) :: :ok
  def unregister_shape(tenant_id, handle) do
    key = {tenant_id, handle}

    case :ets.lookup(@shapes, key) do
      [{^key, info}] ->
        :ets.delete(@shapes, key)
        :ets.delete(@sets, key)
        :ets.match_delete(@index, {{tenant_id, info.inner_schema, info.inner_table}, key})

      [] ->
        :ok
    end

    :ok
  end

  @doc """
  Returns true when `value` is currently in `handle`'s tracked subquery
  result set (ignoring `NOT IN`, which `RestdisElectric.Eval` applies
  itself). False for a shape with no tracked subquery.
  """
  @spec member?(String.t(), String.t(), Eval.value()) :: boolean()
  def member?(tenant_id, handle, value) do
    case :ets.lookup(@sets, {tenant_id, handle}) do
      [{_key, set}] -> MapSet.member?(set, value)
      [] -> false
    end
  end

  @doc """
  Builds an `t:RestdisElectric.Eval.subquery_resolver/0` for `handle`,
  backed by its tracked matching set. Pass this to `Eval.matches?/3` when
  filtering rows for `handle`, whether from a live change or the initial
  snapshot.
  """
  @spec resolver(String.t(), String.t()) :: Eval.subquery_resolver()
  def resolver(tenant_id, handle) do
    fn _table, _column, value -> member?(tenant_id, handle, value) end
  end

  @doc """
  Applies a decoded WAL change on `schema`.`table` to every shape tracking a
  subquery over it, if any. A no-op, and cheap, for a table nothing tracks.

  Called for *every* WAL change, not only ones on a table some shape reads
  directly: the inner table of a tracked subquery typically has no shape of
  its own.
  """
  @spec route_inner_change(String.t(), String.t(), String.t(), map()) :: :ok
  def route_inner_change(tenant_id, schema, table, change) do
    case :ets.lookup(@index, {tenant_id, schema, table}) do
      [] -> :ok
      entries -> Enum.each(entries, fn {_key, shape_key} -> apply_change(shape_key, change) end)
    end

    :ok
  end

  defp apply_change({_tenant_id, _handle} = key, change) do
    %{new_row: new_row, old_row: old_row} = change

    case :ets.lookup(@shapes, key) do
      [{^key, info}] ->
        matched_before = old_row != nil and Eval.matches?(info.inner_filter, old_row)
        matched_after = new_row != nil and Eval.matches?(info.inner_filter, new_row)
        react(key, info, {matched_before, matched_after}, change)

      [] ->
        :ok
    end
  end

  defp react({tenant_id, handle}, info, {false, true}, %{new_row: new_row, lsn: lsn}) do
    transition(tenant_id, handle, info, {Map.get(new_row, info.inner_column), :add, lsn})
  end

  defp react({tenant_id, handle}, info, {true, false}, %{old_row: old_row, lsn: lsn}) do
    transition(tenant_id, handle, info, {Map.get(old_row, info.inner_column), :remove, lsn})
  end

  defp react(_key, _info, {_before, _after}, _change), do: :ok

  defp transition(tenant_id, handle, info, {value, op, lsn}) do
    update_set(tenant_id, handle, value, op)
    effective_op = if info.negated, do: flip(op), else: op
    propagate(handle, info, {value, effective_op, lsn}, tenant_id)
  end

  defp flip(:add), do: :remove
  defp flip(:remove), do: :add

  defp update_set(tenant_id, handle, value, op) do
    key = {tenant_id, handle}

    current =
      case :ets.lookup(@sets, key) do
        [{^key, set}] -> set
        [] -> MapSet.new()
      end

    updated = if op == :add, do: MapSet.put(current, value), else: MapSet.delete(current, value)
    :ets.insert(@sets, {key, updated})
  end

  defp propagate(handle, info, {value, op, lsn}, tenant_id) do
    operation = if op == :add, do: :insert, else: :delete

    case outer_rows(info, value) do
      {:ok, rows} ->
        rows
        |> Enum.filter(&combinator_allows?(info, &1))
        |> Enum.each(&append_message({tenant_id, handle}, info.definition, {operation, &1, lsn}))

      {:error, _reason} ->
        :ok
    end
  end

  # Only a row where "rest" already holds (AND) or does not hold (OR) can have its whole clause flip.
  defp combinator_allows?(%{combinator: :none}, _row), do: true

  defp combinator_allows?(%{combinator: :and, rest_filter: rest}, row),
    do: Eval.matches?(rest, row)

  defp combinator_allows?(%{combinator: :or, rest_filter: rest}, row),
    do: not Eval.matches?(rest, row)

  defp append_message({tenant_id, handle}, definition, {operation, row, lsn}) do
    case TableInfo.fetch(definition.schema, definition.table) do
      {:ok, table_info} ->
        offset = {lsn, :erlang.unique_integer([:monotonic, :positive])}
        key = Enum.map_join(table_info.primary_key, ",", &Map.get(row, &1))
        message = Message.change(offset, operation, key, project(definition, row))
        Log.append(tenant_id, handle, [message])

      :error ->
        :ok
    end
  end

  defp project(%Definition{columns: nil}, row), do: row
  defp project(%Definition{columns: columns}, row), do: Map.take(row, columns)

  # The simplest correct first cut: a full scan of the outer table for `field = value`.
  defp outer_rows(info, value) do
    definition = info.definition

    synthetic = %Definition{
      tenant_id: definition.tenant_id,
      schema: definition.schema,
      table: definition.table
    }

    column = info.outer_column

    scan(info.tenant_config, synthetic, MapSet.new(), fn rows ->
      Enum.filter(rows, &(Map.get(&1, column) == value))
    end)
  end

  defp fetch_matching_set(info) do
    synthetic = %Definition{tenant_id: "", schema: info.inner_schema, table: info.inner_table}
    inner_filter = info.inner_filter
    column = info.inner_column

    scan(info.tenant_config, synthetic, MapSet.new(), fn rows ->
      rows
      |> Enum.filter(&Eval.matches?(inner_filter, &1))
      |> Enum.map(&Map.get(&1, column))
    end)
  end

  # Streams `synthetic`'s whole table, folding each page's rows with `collect` into a `MapSet`.
  defp scan(tenant_config, synthetic, initial, collect) do
    {:ok, acc} = Agent.start_link(fn -> initial end)
    page_fun = fn rows -> Agent.update(acc, &MapSet.union(&1, MapSet.new(collect.(rows)))) end

    result =
      case DirectPostgres.stream(tenant_config, synthetic, page_fun) do
        :ok -> {:ok, Agent.get(acc, & &1)}
        {:error, reason} -> {:error, reason}
      end

    Agent.stop(acc)
    result
  end

  defp build_inner_filter(:none, _params), do: nil

  defp build_inner_filter(selection, params) do
    %Eval{source: "", tree: selection, params: params, columns: Eval.tree_columns(selection)}
  end

  defp build_rest_filter(nil, _params), do: nil

  defp build_rest_filter(rest, params) do
    %Eval{source: "", tree: rest, params: params, columns: Eval.tree_columns(rest)}
  end

  defp split_table(table) do
    case String.split(table, ".", parts: 2) do
      [name] -> {"public", name}
      [schema, name] -> {schema, name}
    end
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@sets, [:set, :public, :named_table, read_concurrency: true])
    :ets.new(@shapes, [:set, :public, :named_table, read_concurrency: true])
    :ets.new(@index, [:bag, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end
end
