defmodule Restdis.Cache.Cluster.Migration do
  @moduledoc """
  Hands tenant aggregates over to their new owner after a rebalance (PRD Phase 6, step 4).

  A tenant whose ring position moved to another node ships its `persist` entries
  to that node and then drops its local ETS table and CubDB instance. Non-persist
  entries are not migrated: they are re-fetched from the origin on the new owner.

  Entries are shipped with a synchronous `:erpc.call/5` and the local copy is
  only flushed once every entry is confirmed applied on the new owner. A
  timeout, a dropped message, or a rejected put (e.g. the peer's persist cap)
  aborts the flush for that tenant, so the node stays the fallback owner and
  the next rebalance retries the handoff instead of silently losing data.
  """

  alias Restdis.Cache.Cluster.HashRing
  alias Restdis.Cache.DiskCache
  alias Restdis.Cache.TenantRegistry

  @doc """
  Migrates every locally running tenant of instance `name` that `ring` assigns to
  another node.

  Returns the tenant ids that were handed over.
  """
  @spec rebalance(HashRing.t(), atom()) :: [String.t()]
  def rebalance(ring, name \\ Restdis.Cache) do
    self_node = Node.self()

    TenantRegistry.local_tenants(name)
    |> Enum.filter(fn tenant_id -> HashRing.owner(ring, tenant_id) not in [nil, self_node] end)
    |> Enum.flat_map(fn tenant_id ->
      owner = HashRing.owner(ring, tenant_id)

      if owner in Node.list(), do: migrate(name, tenant_id, owner), else: []
    end)
  end

  @migrate_timeout_ms 5_000

  defp migrate(name, tenant_id, owner) do
    entries = DiskCache.persisted_entries(name, tenant_id)

    if Enum.all?(entries, &ship_entry(owner, tenant_id, name, &1)) do
      :telemetry.execute(
        [:restdis, :cluster, :migrated],
        %{count: 1, entries: length(entries)},
        %{tenant_id: tenant_id, owner: owner}
      )

      Restdis.Cache.flush_tenant(tenant_id, name)
      [tenant_id]
    else
      :telemetry.execute(
        [:restdis, :cluster, :migration_failed],
        %{count: 1, entries: length(entries)},
        %{tenant_id: tenant_id, owner: owner}
      )

      []
    end
  end

  defp ship_entry(owner, tenant_id, name, {key, value}) do
    case :erpc.call(
           owner,
           Restdis.Cache,
           :put,
           [tenant_id, key, value, [persist: true, replicated: true], name],
           @migrate_timeout_ms
         ) do
      :ok -> true
      _other -> false
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end
end
