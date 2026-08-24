defmodule SupaCacherServer.Rewarm.Supervisor do
  @moduledoc """
  Supervises the rewarm schedulers and their task supervisor.
  """

  use Supervisor

  @doc """
  Starts the rewarm supervision tree.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: SupaCacherServer.Rewarm.Registry},
      {Task.Supervisor, name: SupaCacherServer.Rewarm.TaskSupervisor},
      {DynamicSupervisor, name: SupaCacherServer.Rewarm.DynamicSupervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
