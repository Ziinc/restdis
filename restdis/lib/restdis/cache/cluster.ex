defmodule Restdis.Cache.Cluster do
  @moduledoc """
  Tracks cluster membership and owns the tenant hash ring (PRD Phase 6, steps 2 and 4).

  Membership changes arrive from `:net_kernel.monitor_nodes/1`, which `libcluster`
  drives as it connects and disconnects peers. Every change rebuilds the ring,
  emits a rebalance event and hands off tenants this node no longer owns.
  """

  use GenServer

  alias Restdis.Cache.Cluster.HashRing
  alias Restdis.Cache.Cluster.Migration

  @ring_key {__MODULE__, :ring}

  @doc """
  Starts the membership tracker.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the current hash ring.
  """
  @spec ring() :: HashRing.t()
  def ring do
    :persistent_term.get(@ring_key, HashRing.new([Node.self()]))
  end

  @doc """
  Returns the node owning `tenant_id`.
  """
  @spec owner(String.t()) :: node()
  def owner(tenant_id) do
    HashRing.owner(ring(), tenant_id) || Node.self()
  end

  @doc """
  Returns true when this node owns `tenant_id`.
  """
  @spec local?(String.t()) :: boolean()
  def local?(tenant_id), do: owner(tenant_id) == Node.self()

  @doc false
  @spec sync() :: :ok
  def sync, do: GenServer.call(__MODULE__, :sync)

  @impl GenServer
  def init(_opts) do
    :ok = :net_kernel.monitor_nodes(true)
    put_ring(HashRing.new([Node.self() | Node.list()]))
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call(:sync, _from, state), do: {:reply, :ok, state}

  @impl GenServer
  def handle_info({:nodeup, node}, state) do
    apply_membership(&HashRing.add_node(&1, node), :join, node)
    {:noreply, state}
  end

  def handle_info({:nodedown, node}, state) do
    apply_membership(&HashRing.remove_node(&1, node), :leave, node)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp apply_membership(fun, change, node) do
    new_ring = fun.(ring())
    put_ring(new_ring)

    :telemetry.execute(
      [:restdis, :cluster, :rebalance],
      %{count: 1, nodes: length(HashRing.nodes(new_ring))},
      %{change: change, node: node}
    )

    Migration.rebalance(new_ring)
  end

  defp put_ring(ring), do: :persistent_term.put(@ring_key, ring)
end
