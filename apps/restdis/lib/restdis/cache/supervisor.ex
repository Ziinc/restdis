defmodule Restdis.Cache.Supervisor do
  @moduledoc """
  Supervision tree of the cache bounded context.

  A plain dependency on `:restdis` starts no processes: `mix.exs` declares no
  `mod:` application callback. A host mounts this supervisor explicitly, for
  example `{Restdis.Cache, []}` in its own supervision tree (LIB_PRD Phase 5).
  """

  use Supervisor

  @doc """
  Starts the cache supervision tree.

  Pass `:name` to run more than one instance in the same VM without
  colliding on the top-level supervisor's registered name. Defaults to
  `__MODULE__`.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    # Idempotent by name: several host apps' test_helper.exs mount the default instance defensively in one shared VM.
    case Process.whereis(name) do
      nil -> Supervisor.start_link(__MODULE__, opts, name: name)
      pid -> {:ok, pid}
    end
  end

  @impl Supervisor
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: Restdis.Cache.TenantRegistry},
      Restdis.Cache.TenantSupervisor,
      Restdis.Cache.Replication.Receiver,
      Restdis.Cache.Cluster
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
