defmodule RestdisElectric.Supervisor do
  @moduledoc """
  Supervision tree for the shape context: the log process registry, the
  dynamic supervisor that owns one process per active shape, the shape
  filter's hash index, and the registry of shapes reading each table.
  """

  use Supervisor

  @doc """
  Starts the supervision tree.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: RestdisElectric.Log.Registry},
      {DynamicSupervisor, name: RestdisElectric.Log.Supervisor, strategy: :one_for_one},
      RestdisElectric.Filter,
      RestdisElectric.ShapeRegistry,
      RestdisElectric.Limits,
      RestdisElectric.SchemaWatcher,
      RestdisElectric.SubqueryTracker
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
