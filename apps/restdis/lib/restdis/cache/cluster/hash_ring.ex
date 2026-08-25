defmodule Restdis.Cache.Cluster.HashRing do
  @moduledoc """
  Consistent hash ring with virtual nodes, keyed by tenant id (PRD Phase 6, step 2).

  Each node is placed on the ring `@virtual_nodes` times so tenant ownership stays
  even and a node join or departure only moves the tenants that hash into the
  affected arcs.
  """

  @type t :: %__MODULE__{points: [{non_neg_integer(), node()}], nodes: [node()]}

  defstruct points: [], nodes: []

  @virtual_nodes 128

  @doc """
  Builds a ring holding `nodes`.
  """
  @spec new([node()]) :: t()
  def new(nodes) do
    Enum.reduce(nodes, %__MODULE__{}, &add_node(&2, &1))
  end

  @doc """
  Returns the sorted node list of `ring`.
  """
  @spec nodes(t()) :: [node()]
  def nodes(%__MODULE__{nodes: nodes}), do: nodes

  @doc """
  Adds `node` to `ring`, a no-op when it is already a member.
  """
  @spec add_node(t(), node()) :: t()
  def add_node(%__MODULE__{nodes: nodes} = ring, node) do
    if node in nodes do
      ring
    else
      points = Enum.sort(ring.points ++ virtual_points(node))
      %__MODULE__{ring | points: points, nodes: Enum.sort([node | nodes])}
    end
  end

  @doc """
  Removes `node` from `ring`.
  """
  @spec remove_node(t(), node()) :: t()
  def remove_node(%__MODULE__{} = ring, node) do
    %__MODULE__{
      ring
      | points: Enum.reject(ring.points, fn {_hash, member} -> member == node end),
        nodes: Enum.reject(ring.nodes, &(&1 == node))
    }
  end

  @doc """
  Returns the node owning `tenant_id`, or nil when the ring is empty.
  """
  @spec owner(t(), String.t()) :: node() | nil
  def owner(%__MODULE__{points: []}, _tenant_id), do: nil

  def owner(%__MODULE__{points: points}, tenant_id) do
    hash = :erlang.phash2(tenant_id)

    case Enum.find(points, fn {point, _node} -> point >= hash end) do
      {_point, node} -> node
      nil -> points |> hd() |> elem(1)
    end
  end

  defp virtual_points(node) do
    Enum.map(1..@virtual_nodes, fn index ->
      {:erlang.phash2({node, index}), node}
    end)
  end
end
