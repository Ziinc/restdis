defmodule Restdis.Cache.Cluster do
  @moduledoc """
  Tracks cluster membership and owns the tenant hash ring (PRD Phase 6, steps 2 and 4).

  Membership changes arrive from `:net_kernel.monitor_nodes/1`, which `libcluster`
  drives as it connects and disconnects peers. Every change rebuilds the ring,
  emits a rebalance event and hands off tenants this node no longer owns.

  Scoped by cache instance `name`, so a second `Restdis.Cache` instance in the
  same VM gets its own registered process and its own hash ring rather than
  colliding with the first.
  """

  use GenServer

  alias Restdis.Cache.Cluster.HashRing
  alias Restdis.Cache.Cluster.Migration

  @doc """
  Returns the registered name of the cluster tracker belonging to instance `name`.
  """
  @spec process_name(atom()) :: atom()
  def process_name(name), do: Module.concat(name, __MODULE__)

  @doc """
  Starts the membership tracker for instance `:name`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: process_name(name))
  end

  @doc """
  Returns the current hash ring of instance `name`.
  """
  @spec ring(atom()) :: HashRing.t()
  def ring(name \\ Restdis.Cache) do
    :persistent_term.get(ring_key(name), HashRing.new([Node.self()]))
  end

  @doc """
  Returns the node owning `tenant_id` in instance `name`.
  """
  @spec owner(String.t(), atom()) :: node()
  def owner(tenant_id, name \\ Restdis.Cache) do
    HashRing.owner(ring(name), tenant_id) || Node.self()
  end

  @doc """
  Returns true when this node owns `tenant_id` in instance `name`.
  """
  @spec local?(String.t(), atom()) :: boolean()
  def local?(tenant_id, name \\ Restdis.Cache), do: owner(tenant_id, name) == Node.self()

  @doc false
  @spec sync(atom()) :: :ok
  def sync(name \\ Restdis.Cache), do: GenServer.call(process_name(name), :sync)

  @impl GenServer
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    :ok = :net_kernel.monitor_nodes(true)
    put_ring(name, HashRing.new([Node.self() | Node.list()]))
    {:ok, %{name: name}}
  end

  @impl GenServer
  def handle_call(:sync, _from, state), do: {:reply, :ok, state}

  @impl GenServer
  def handle_info({:nodeup, node}, %{name: name} = state) do
    apply_membership(name, &HashRing.add_node(&1, node), :join, node)
    {:noreply, state}
  end

  def handle_info({:nodedown, node}, %{name: name} = state) do
    apply_membership(name, &HashRing.remove_node(&1, node), :leave, node)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp apply_membership(name, fun, change, node) do
    new_ring = fun.(ring(name))
    put_ring(name, new_ring)

    :telemetry.execute(
      [:restdis, :cluster, :rebalance],
      %{count: 1, nodes: length(HashRing.nodes(new_ring))},
      %{change: change, node: node}
    )

    Migration.rebalance(new_ring, name)
  end

  defp put_ring(name, ring), do: :persistent_term.put(ring_key(name), ring)

  defp ring_key(name), do: {__MODULE__, name, :ring}
end
