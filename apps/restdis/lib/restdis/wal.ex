defmodule Restdis.Wal do
  @moduledoc """
  Postgres WAL follower: tails a logical replication slot and hands every decoded
  change to the host's `Restdis.Wal.Handler`. Mount it in a host supervisor:

      {Restdis.Wal,
       repo: MyApp.Repo,
       replication: [url: System.fetch_env!("DATABASE_URL")],
       slot_name: "my_slot",
       publication: "my_pub",
       handler: MyApp.WalHandler}

  Options:

    * `:handler` (required) - the `Restdis.Wal.Handler` that receives each event.
    * `:repo` - the Ecto repo holding `<prefix>.wal_checkpoint`; required unless `:temporary`.
    * `:name` - the instance name, defaulting to `Restdis.Wal`.
    * `:prefix` - the schema of `wal_checkpoint`, defaulting to `"restdis"`.
    * `:replication` - Postgrex connection options for the replication connection; a
      `:url` is expanded. Logical replication needs a direct connection, not a pooler.
    * `:slot_name` / `:publication` - default to `"restdis_slot"` / `"restdis_pub"`.
    * `:topology` - `:syn` (default, recommended) elects one tailer per cluster through
      `:syn` and fans each event out to every node, so the host must depend on `:syn`.
      `:local` runs a tailer on every node without `:syn`; give each node its own slot.
    * `:az` - this node's availability zone for the `:syn` fanout, defaulting to `"local"`.
    * `:temporary` - `true` tails a temporary slot instead, named `<slot_name>_<random>`,
      which Postgres drops when its connection closes, so no slot is left holding WAL and
      no checkpoint is kept. Each new slot starts at the current WAL position: changes
      committed while no slot was open (during a takeover or a reconnect) are never seen.
      Defaults to `false`.
    * `:on_takeover` - an `{m, f, a}` run when this node becomes the tailer, to close the
      gap a failover can leave. With `:temporary`, it runs instead each time the tailer
      creates its slot, once the slot exists, in a separate process.
    * `:telemetry_prefix` - prepended to the follower's telemetry events, defaulting to
      `[:restdis]`.
  """

  use Supervisor

  alias Restdis.Wal.FanoutSubscriber
  alias Restdis.Wal.InstanceConfig
  alias Restdis.Wal.LsnStore
  alias Restdis.Wal.Singleton
  alias Restdis.Wal.Tailer

  @doc """
  Returns the child spec of the follower instance named in `opts`.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.get(opts, :name, __MODULE__)},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc """
  Starts the follower instance described by `opts`; see the module doc for the options.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    Supervisor.start_link(__MODULE__, Keyword.put(opts, :name, name),
      name: Module.concat(name, Supervisor)
    )
  end

  @impl Supervisor
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    unless Keyword.has_key?(opts, :handler), do: raise(ArgumentError, ":handler is required")
    :ok = InstanceConfig.put(name, opts)

    Supervisor.init(children(name, InstanceConfig.fetch!(name).topology), strategy: :one_for_one)
  end

  defp children(name, :syn) do
    :ok = :syn.add_node_to_scopes([:wal, :wal_fanout])

    [
      {LsnStore, name: name},
      {DynamicSupervisor, name: Module.concat(name, TailerSupervisor), strategy: :one_for_one},
      {FanoutSubscriber, name: name},
      {Singleton, name: name}
    ]
  end

  defp children(name, :local), do: [{LsnStore, name: name}, {Tailer, name: name}]
end
