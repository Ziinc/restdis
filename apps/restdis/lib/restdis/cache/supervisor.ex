defmodule Restdis.Cache.Supervisor do
  @moduledoc """
  Supervision tree of the cache bounded context.

  A plain dependency on `:restdis` starts no processes: `mix.exs` declares no
  `mod:` application callback. A host mounts this supervisor explicitly, for
  example `{Restdis.Cache, data_dir: ..., origin: ..., repo: ..., prefix: ...}`
  in its own supervision tree (LIB_PRD Phase 5).

  Reads no `:restdis_*` application environment: every option is resolved once
  here into `Restdis.Cache.InstanceConfig`, keyed by `:name`, and every process
  in the tree below is named from that same `:name` so a second instance in the
  same VM does not collide with the first.
  """

  use Supervisor

  alias Restdis.Cache.InstanceConfig
  alias Restdis.Cache.TenantRegistry

  @doc """
  Starts the cache supervision tree.

  Pass `:name` to run more than one instance in the same VM: it names the
  top-level supervisor and scopes every child process (the tenant registry,
  the tenant supervisor, the replication receiver and the cluster tracker)
  underneath it, so a second instance with a different `:name` does not
  collide with the first. Defaults to `Restdis.Cache`, matching the default
  instance every `Restdis.Cache` function operates on.

  Also accepts `:data_dir`, `:origin`, `:repo`, `:prefix` and the cache's
  resource caps (`:ets_cap_bytes`, `:cubdb_cap_bytes`, `:persist_cap`,
  `:replication_transport`), resolved once into `Restdis.Cache.InstanceConfig`
  under `:name`.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, Restdis.Cache)

    # Idempotent by name: several host apps' test_helper.exs mount the default instance defensively in one shared VM.
    case Process.whereis(name) do
      nil ->
        InstanceConfig.put(name, opts)
        Supervisor.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)

      pid ->
        {:ok, pid}
    end
  end

  @impl Supervisor
  def init(opts) do
    name = Keyword.fetch!(opts, :name)

    children = [
      {Registry, keys: :unique, name: TenantRegistry.registry_name(name)},
      {Restdis.Cache.TenantSupervisor, name: name},
      {Restdis.Cache.Replication.Receiver, name: name},
      Restdis.Cache.HotCache,
      Restdis.Cache.HotCache.Receiver,
      {Restdis.Cache.Cluster, name: name}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
