defmodule Restdis.Cache.HotCache do
  @moduledoc """
  Cluster-wide hot-query cache: a single extra in-memory layer, identical on
  every node, sitting in front of the per-tenant owner-routed cache.

  Unlike `Restdis.Cache`/`Restdis.Cache.Router`, where a tenant's data lives
  on exactly one owning node and every other node must hop to it, an entry
  here is stored locally on the very first access and pushed to every peer
  once it turns "hot", so a hit for it never needs a cross-node call at all.

  Every entry is stored locally the first time it is observed, with a TTL of
  the underlying entry's remaining TTL capped at five minutes, so a hot entry
  never outlives the entry it was read from. Every invalidation path of
  `Restdis.Cache` clears it through `delete/3` (or `delete_tenant/2` for a
  whole tenant). The layer holds at most 100_000 entries (overridable via
  the `:hot_cache_max_entries` app env) and evicts arbitrary older entries
  beyond that. Once its local access count (tracked per node) reaches 5
  within one sweep window, the node gossips the value to every peer.
  A peer applies the gossiped entry to its own copy of this same layer but
  never re-broadcasts it, which bounds propagation of any one entry to a
  single hop, the same bound `Restdis.Cache.Replication` uses for persisted
  disk-cache writes.
  """

  use GenServer

  alias Restdis.Cache.Key

  @store :restdis_hot_cache_store
  @counters :restdis_hot_cache_counters

  @propagate_at 5
  @ttl_ms 5 * 60 * 1_000
  @sweep_interval_ms 10_000
  @max_entries 100_000

  @type gossip_message ::
          {:sc_hot_cache_put, Restdis.Cache.tenant_id(), Key.t(), term(), pos_integer()}
          | {:sc_hot_cache_delete, Restdis.Cache.tenant_id(), Key.t()}
          | {:sc_hot_cache_delete_tenant, Restdis.Cache.tenant_id()}

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Reads `key` from the hot layer, treating an expired entry as a miss.
  """
  @spec get(Restdis.Cache.tenant_id(), Key.t()) :: {:ok, term()} | :miss
  def get(tenant_id, key) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@store, {tenant_id, key}) do
      [{_, value, expires_at}] when expires_at > now ->
        {:ok, value}

      [{_, _, _}] ->
        :ets.delete(@store, {tenant_id, key})
        :miss

      [] ->
        :miss
    end
  end

  @doc """
  Records a hit for `key` obtained elsewhere (the owner-routed cache or the
  origin).

  Stores it in the hot layer immediately, on this first access, for
  `remaining_ttl_ms` (the underlying entry's remaining TTL) capped at five
  minutes. Once the local access count for it reaches the propagation
  threshold, gossips it to every peer so their copy of the hot layer picks it
  up too.
  """
  @spec observe(Restdis.Cache.tenant_id(), Key.t(), term(), non_neg_integer() | :infinity) :: :ok
  def observe(tenant_id, key, value, remaining_ttl_ms) do
    ttl_ms = cap_ttl(remaining_ttl_ms)
    put_local(tenant_id, key, value, ttl_ms)

    composite = {tenant_id, key}
    count = :ets.update_counter(@counters, composite, {2, 1}, {composite, 0})

    if count == @propagate_at do
      :telemetry.execute([:restdis, :hot_cache, :promoted], %{count: 1}, %{tenant_id: tenant_id})
      :ok = transport().broadcast({:sc_hot_cache_put, tenant_id, key, value, ttl_ms})
    end

    :ok
  end

  @doc """
  Removes `key` from the hot layer and, unless `opts[:gossiped]` is set,
  gossips the delete to every peer so stale hot copies do not outlive the
  underlying data.
  """
  @spec delete(Restdis.Cache.tenant_id(), Key.t(), keyword()) :: :ok
  def delete(tenant_id, key, opts \\ []) do
    composite = {tenant_id, key}
    :ets.delete(@store, composite)
    :ets.delete(@counters, composite)

    unless opts[:gossiped] do
      :ok = transport().broadcast({:sc_hot_cache_delete, tenant_id, key})

      :telemetry.execute([:restdis, :hot_cache, :gossip_delete], %{count: 1}, %{
        tenant_id: tenant_id
      })
    end

    :ok
  end

  @doc """
  Removes every entry of `tenant_id` from the hot layer and, unless
  `opts[:gossiped]` is set, gossips the delete to every peer.
  """
  @spec delete_tenant(Restdis.Cache.tenant_id(), keyword()) :: :ok
  def delete_tenant(tenant_id, opts \\ []) do
    :ets.match_delete(@store, {{tenant_id, :_}, :_, :_})
    :ets.match_delete(@counters, {{tenant_id, :_}, :_})

    unless opts[:gossiped] do
      :ok = transport().broadcast({:sc_hot_cache_delete_tenant, tenant_id})
    end

    :ok
  end

  @doc """
  Returns the number of entries held in this node's hot layer.
  """
  @spec size() :: non_neg_integer()
  def size, do: :ets.info(@store, :size)

  @doc """
  Applies a peer's gossiped promotion locally without re-broadcasting it.
  """
  @spec apply_gossip_put(Restdis.Cache.tenant_id(), Key.t(), term(), pos_integer()) :: :ok
  def apply_gossip_put(tenant_id, key, value, ttl_ms) do
    put_local(tenant_id, key, value, ttl_ms)

    :telemetry.execute([:restdis, :hot_cache, :gossip_applied], %{count: 1}, %{
      tenant_id: tenant_id
    })

    :ok
  end

  @doc """
  Applies a peer's gossiped delete locally without re-broadcasting it.
  """
  @spec apply_gossip_delete(Restdis.Cache.tenant_id(), Key.t()) :: :ok
  def apply_gossip_delete(tenant_id, key), do: delete(tenant_id, key, gossiped: true)

  @doc """
  Applies a peer's gossiped tenant delete locally without re-broadcasting it.
  """
  @spec apply_gossip_delete_tenant(Restdis.Cache.tenant_id()) :: :ok
  def apply_gossip_delete_tenant(tenant_id), do: delete_tenant(tenant_id, gossiped: true)

  @doc false
  @spec flush() :: :ok
  def flush do
    :ets.delete_all_objects(@store)
    :ets.delete_all_objects(@counters)
    :ok
  end

  defp cap_ttl(:infinity), do: @ttl_ms
  defp cap_ttl(remaining_ttl_ms), do: min(remaining_ttl_ms, @ttl_ms)

  defp put_local(tenant_id, key, value, ttl_ms) do
    expires_at = System.monotonic_time(:millisecond) + ttl_ms
    :ets.insert(@store, {{tenant_id, key}, value, expires_at})
    max_entries = Application.get_env(:restdis, :hot_cache_max_entries, @max_entries)
    evict_over_cap({tenant_id, key}, max_entries)
  end

  defp evict_over_cap(inserted, max_entries) do
    if :ets.info(@store, :size) > max_entries do
      case eviction_victim(:ets.first(@store), inserted) do
        :"$end_of_table" ->
          :ok

        victim ->
          :ets.delete(@store, victim)
          :ets.delete(@counters, victim)
          evict_over_cap(inserted, max_entries)
      end
    else
      :ok
    end
  end

  # Never evicts the entry that was just inserted.
  defp eviction_victim(inserted, inserted), do: :ets.next(@store, inserted)
  defp eviction_victim(candidate, _inserted), do: candidate

  defp transport do
    Application.get_env(
      :restdis,
      :hot_cache_transport,
      Restdis.Cache.HotCache.Transport.Distribution
    )
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@store, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    :ets.new(@counters, [:set, :public, :named_table, write_concurrency: true])

    schedule_sweep()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)

    :ets.select_delete(@store, [
      {{:_, :_, :"$1"}, [{:<, :"$1", {:const, now}}], [true]}
    ])

    # Resets access counts each window instead of accumulating them forever.
    :ets.delete_all_objects(@counters)

    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
