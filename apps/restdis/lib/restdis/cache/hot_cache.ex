defmodule Restdis.Cache.HotCache do
  @moduledoc """
  Cluster-wide hot-query cache: a single extra in-memory layer, identical on
  every node, sitting in front of the per-tenant owner-routed cache.

  Unlike `Restdis.Cache`/`Restdis.Cache.Router`, where a tenant's data lives
  on exactly one owning node and every other node must hop to it,
  entries here are pushed to every peer as soon as they turn "hot", so a hit
  never needs a cross-node call at all.

  A key turns hot once its local access count (tracked per node) crosses
  `:hot_cache_threshold` (default 5) within one sweep window. The node that
  promotes it gossips the value to every peer. A peer applies the gossiped
  entry to its own copy of this same layer but never re-broadcasts it, which
  bounds propagation of any one entry to a single hop, the same bound
  `Restdis.Cache.Replication` uses for persisted disk-cache writes.
  """

  use GenServer

  alias Restdis.Cache.Key

  @store :restdis_hot_cache_store
  @counters :restdis_hot_cache_counters

  @default_threshold 5
  @default_ttl_ms 5_000
  @sweep_interval_ms 10_000

  @type gossip_message ::
          {:sc_hot_cache_put, Restdis.Cache.tenant_id(), Key.t(), term(), pos_integer()}
          | {:sc_hot_cache_delete, Restdis.Cache.tenant_id(), Key.t()}

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
  origin), promoting it to the hot layer and gossiping it to every peer once
  the local access count for it crosses the hotness threshold.
  """
  @spec observe(Restdis.Cache.tenant_id(), Key.t(), term()) :: :ok
  def observe(tenant_id, key, value) do
    threshold = Application.get_env(:restdis, :hot_cache_threshold, @default_threshold)
    composite = {tenant_id, key}
    count = :ets.update_counter(@counters, composite, {2, 1}, {composite, 0})

    if count >= threshold do
      :ets.delete(@counters, composite)
      promote(tenant_id, key, value)
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

  @doc false
  @spec flush() :: :ok
  def flush do
    :ets.delete_all_objects(@store)
    :ets.delete_all_objects(@counters)
    :ok
  end

  defp promote(tenant_id, key, value) do
    ttl_ms = Application.get_env(:restdis, :hot_cache_ttl_ms, @default_ttl_ms)
    put_local(tenant_id, key, value, ttl_ms)

    :telemetry.execute([:restdis, :hot_cache, :promoted], %{count: 1}, %{tenant_id: tenant_id})

    :ok = transport().broadcast({:sc_hot_cache_put, tenant_id, key, value, ttl_ms})
    :ok
  end

  defp put_local(tenant_id, key, value, ttl_ms) do
    expires_at = System.monotonic_time(:millisecond) + ttl_ms
    :ets.insert(@store, {{tenant_id, key}, value, expires_at})
  end

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

    # Bounds the counters table and re-evaluates hotness per window rather
    # than accumulating access counts forever.
    :ets.delete_all_objects(@counters)

    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
