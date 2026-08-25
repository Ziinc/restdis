defmodule Restdis.Cache.Cluster.Migration do
  @moduledoc """
  Hands tenant aggregates over to their new owner after a rebalance (PRD Phase 6, step 4).

  A tenant whose ring position moved to another node ships its `persist` entries
  to that node and then drops its local ETS table and CubDB instance. Non-persist
  entries are not migrated: they are re-fetched from the origin on the new owner.
  """

  alias Restdis.Cache.Cluster.HashRing
  alias Restdis.Cache.DiskCache
  alias Restdis.Cache.TenantRegistry

  @doc """
  Migrates every locally running tenant that `ring` assigns to another node.

  Returns the tenant ids that were handed over.
  """
  @spec rebalance(HashRing.t()) :: [String.t()]
  def rebalance(ring) do
    self_node = Node.self()

    TenantRegistry.local_tenants()
    |> Enum.filter(fn tenant_id -> HashRing.owner(ring, tenant_id) not in [nil, self_node] end)
    |> Enum.flat_map(fn tenant_id ->
      owner = HashRing.owner(ring, tenant_id)

      if owner in Node.list(), do: migrate(tenant_id, owner), else: []
    end)
  end

  defp migrate(tenant_id, owner) do
    entries = DiskCache.persisted_entries(tenant_id)

    Enum.each(entries, fn {key, value} ->
      :erpc.cast(owner, Restdis.Cache, :put, [
        tenant_id,
        key,
        value,
        [persist: true, replicated: true]
      ])
    end)

    :telemetry.execute(
      [:restdis, :cluster, :migrated],
      %{count: 1, entries: length(entries)},
      %{tenant_id: tenant_id, owner: owner}
    )

    Restdis.Cache.flush_tenant(tenant_id)
    [tenant_id]
  end
end
