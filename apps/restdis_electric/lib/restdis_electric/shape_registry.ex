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

  @table __MODULE__

  @doc """
  Starts the registry's ETS table.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers `handle` as reading `schema`.`table` for `tenant_id`.
  """
  @spec register(String.t(), String.t(), String.t(), String.t()) :: :ok
  def register(tenant_id, schema, table, handle) do
    :ets.insert(@table, {{tenant_id, schema, table}, handle})
    :ok
  end

  @doc """
  Removes `handle` from the index.
  """
  @spec unregister(String.t(), String.t()) :: :ok
  def unregister(tenant_id, handle) do
    :ets.match_delete(@table, {{tenant_id, :_, :_}, handle})
    :ok
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
    {:ok, %{}}
  end
end
