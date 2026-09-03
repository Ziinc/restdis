defmodule RestdisElectric.ShapeRegistry do
  @moduledoc """
  In-memory index from `(tenant_id, schema, table)` to the handles of the
  shapes currently reading that table on this node.

  `RestdisElectric.WAL.ingest/1` consults this index for every decoded
  change so it only tests, and appends to, shapes that actually read the
  changed table. A shape is registered the moment a client subscribes to it
  (`RestdisElectric.subscribe/3`); it is not restored automatically after a
  node restart until a client subscribes again. Until then, the shape's log
  simply stops advancing rather than losing data: the log itself survives on
  disk, and a client that resumes only sees a gap once the shape is
  re-registered and catches up.
  """

  use GenServer

  alias RestdisElectric.Definition
  alias RestdisElectric.Filter

  @table __MODULE__
  @shapes __MODULE__.Shapes

  @doc """
  Starts the registry's ETS table.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers `handle` as reading `schema`.`table` for `tenant_id`, with no
  filter, so every change to that table reaches it.
  """
  @spec register(String.t(), String.t(), String.t(), String.t()) :: :ok
  def register(tenant_id, schema, table, handle) do
    register(
      tenant_id,
      %Definition{tenant_id: tenant_id, schema: schema, table: table},
      handle
    )
  end

  @doc """
  Registers `handle` for `definition`, keeping the definition so
  `RestdisElectric.WAL` can apply its filter, column list and replica mode to
  each change, and indexing it in `RestdisElectric.Filter`.
  """
  @spec register(String.t(), Definition.t(), String.t()) :: :ok
  def register(tenant_id, %Definition{} = definition, handle) do
    :ets.insert(@table, {{tenant_id, definition.schema, definition.table}, handle})
    :ets.insert(@shapes, {{tenant_id, handle}, definition})
    Filter.add(tenant_id, definition, handle)
    :ok
  end

  @doc """
  Returns the definition registered for `handle`, if there is one.
  """
  @spec fetch(String.t(), String.t()) :: {:ok, Definition.t()} | :error
  def fetch(tenant_id, handle) do
    if :ets.whereis(@shapes) == :undefined do
      :error
    else
      case :ets.lookup(@shapes, {tenant_id, handle}) do
        [{_key, definition} | _] -> {:ok, definition}
        [] -> :error
      end
    end
  end

  @doc """
  Removes `handle` from the index.
  """
  @spec unregister(String.t(), String.t()) :: :ok
  def unregister(tenant_id, handle) do
    :ets.match_delete(@table, {{tenant_id, :_, :_}, handle})
    :ets.delete(@shapes, {tenant_id, handle})
    Filter.remove(tenant_id, handle)
    :ok
  end

  @doc """
  Returns every distinct `{tenant_id, schema, table}` with at least one
  registered shape, across all tenants.

  Used by periodic schema-drift detection to know which tables need their
  cached metadata compared against the real schema.
  """
  @spec tables() :: [{String.t(), String.t(), String.t()}]
  def tables do
    if :ets.whereis(@table) == :undefined do
      []
    else
      @table
      |> :ets.select([{{{:"$1", :"$2", :"$3"}, :_}, [], [{{:"$1", :"$2", :"$3"}}]}])
      |> Enum.uniq()
    end
  end

  @doc """
  Returns the number of shapes currently registered for `tenant_id`.
  """
  @spec count(String.t()) :: non_neg_integer()
  def count(tenant_id) do
    if :ets.whereis(@shapes) == :undefined do
      0
    else
      :ets.select_count(@shapes, [{{{tenant_id, :_}, :_}, [], [true]}])
    end
  end

  @doc """
  Returns the number of currently registered shapes for every tenant that has
  at least one, as `{tenant_id, count}` pairs. Used for the "active shapes
  per tenant" gauge polled by the host application.
  """
  @spec active_counts() :: [{String.t(), non_neg_integer()}]
  def active_counts do
    if :ets.whereis(@shapes) == :undefined do
      []
    else
      @shapes
      |> :ets.select([{{{:"$1", :_}, :_}, [], [:"$1"]}])
      |> Enum.frequencies()
      |> Map.to_list()
    end
  end

  @doc """
  Returns every handle registered for `tenant_id`'s `schema`.`table`.
  """
  @spec handles_for(String.t(), String.t(), String.t()) :: [String.t()]
  def handles_for(tenant_id, schema, table) do
    if :ets.whereis(@table) == :undefined do
      []
    else
      @table
      |> :ets.lookup({tenant_id, schema, table})
      |> Enum.map(fn {_key, handle} -> handle end)
    end
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:bag, :public, :named_table, read_concurrency: true])
    :ets.new(@shapes, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end
end
