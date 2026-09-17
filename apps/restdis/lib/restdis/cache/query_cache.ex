defmodule Restdis.Cache.QueryCache do
  @moduledoc """
  Per-tenant ETS query cache holding cached PostgREST responses and their TTLs.
  """

  use GenServer

  alias Restdis.Cache.InstanceConfig
  alias Restdis.Cache.Key
  alias Restdis.Cache.TenantRegistry

  @sweep_interval_ms 30_000

  @doc """
  Returns the child spec of the query cache for `tenant_id` under instance `name`.
  """
  @spec child_spec(atom(), String.t()) :: Supervisor.child_spec()
  def child_spec(name, tenant_id) do
    %{
      id: {__MODULE__, name, tenant_id},
      start: {__MODULE__, :start_link, [name, tenant_id]},
      type: :worker,
      restart: :permanent
    }
  end

  @doc """
  Starts the query cache for `tenant_id` under instance `name`.
  """
  @spec start_link(atom(), String.t()) :: GenServer.on_start()
  def start_link(name, tenant_id) do
    GenServer.start_link(__MODULE__, {name, tenant_id},
      name: TenantRegistry.via(name, tenant_id, :query_cache)
    )
  end

  @doc """
  Reads `key`, treating an expired entry as a miss.
  """
  @spec get(atom(), String.t(), Key.t()) :: {:ok, term()} | :miss
  def get(name, tenant_id, key) do
    {tid, idx} = tables(name, tenant_id)
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(tid, key) do
      [{^key, value, :infinity, last_access}] ->
        touch(tid, idx, key, last_access)
        {:ok, value}

      [{^key, value, expires_at, last_access}] when expires_at > now ->
        touch(tid, idx, key, last_access)
        {:ok, value}

      [{^key, _, _, last_access}] ->
        :ets.delete(tid, key)
        :ets.delete(idx, {last_access, key})
        :miss

      [] ->
        :miss
    end
  end

  @doc """
  Writes `value` under `key`, expiring it after `opts[:ttl_ms]`. `opts[:name]`
  selects the cache instance (required).

  Enforces the per-instance ETS memory cap (`:ets_cap_bytes` in
  `Restdis.Cache.InstanceConfig`, defaulting to 500 MB) by evicting the
  least-recently-used entries when the write pushes the tenant's table over
  the cap.
  """
  @spec put(String.t(), Key.t(), term(), keyword()) :: :ok
  def put(tenant_id, key, value, opts \\ []) do
    name = Keyword.fetch!(opts, :name)
    {tid, idx} = tables(name, tenant_id)

    expires_at =
      case opts[:ttl_ms] do
        nil -> :infinity
        ms -> System.monotonic_time(:millisecond) + ms
      end

    now = System.monotonic_time()

    case :ets.lookup(tid, key) do
      [{^key, _, _, old_last_access}] -> :ets.delete(idx, {old_last_access, key})
      [] -> :ok
    end

    :ets.insert(tid, {key, value, expires_at, now})
    :ets.insert(idx, {{now, key}})
    evict_over_cap(name, tenant_id, tid, idx)
    :ok
  end

  @doc """
  Returns the milliseconds remaining before `key` expires, `:infinity` for a
  key with no TTL, or `:miss` if it isn't held in this tenant's query cache.

  Unlike `get/2`, this does not touch the entry's LRU recency.
  """
  @spec ttl_ms(atom(), String.t(), Key.t()) :: non_neg_integer() | :infinity | :miss
  def ttl_ms(name, tenant_id, key) do
    case TenantRegistry.get_value(name, tenant_id, :qc_table) do
      nil ->
        :miss

      tid ->
        case :ets.lookup(tid, key) do
          [{^key, _value, :infinity, _last_access}] ->
            :infinity

          [{^key, _value, expires_at, _last_access}] ->
            now = System.monotonic_time(:millisecond)
            max(0, expires_at - now)

          [] ->
            :miss
        end
    end
  end

  @doc """
  Returns the approximate memory footprint, in bytes, of the tenant's ETS
  query cache table.
  """
  @spec memory_bytes(atom(), String.t()) :: non_neg_integer()
  def memory_bytes(name, tenant_id) do
    {tid, _idx} = tables(name, tenant_id)
    :ets.info(tid, :memory) * :erlang.system_info(:wordsize)
  end

  defp touch(tid, idx, key, old_last_access) do
    new_last_access = System.monotonic_time()
    :ets.delete(idx, {old_last_access, key})
    :ets.insert(idx, {{new_last_access, key}})
    :ets.update_element(tid, key, {4, new_last_access})
  end

  defp evict_over_cap(name, tenant_id, tid, idx) do
    cap = InstanceConfig.get(name, :ets_cap_bytes, 500 * 1024 * 1024)
    do_evict_over_cap(tenant_id, tid, idx, cap)
  end

  defp do_evict_over_cap(tenant_id, tid, idx, cap) do
    mem_bytes = :ets.info(tid, :memory) * :erlang.system_info(:wordsize)

    if mem_bytes > cap do
      case :ets.first(idx) do
        :"$end_of_table" ->
          :ok

        {_last_access, lru_key} = idx_entry ->
          :ets.delete(tid, lru_key)
          :ets.delete(idx, idx_entry)

          :telemetry.execute([:restdis, :cache, :ets_evict], %{count: 1}, %{
            tenant_id: tenant_id,
            key: lru_key
          })

          do_evict_over_cap(tenant_id, tid, idx, cap)
      end
    else
      :ok
    end
  end

  @doc """
  Removes `key` from the query cache.
  """
  @spec delete(atom(), String.t(), Key.t()) :: :ok
  def delete(name, tenant_id, key) do
    {tid, idx} = tables(name, tenant_id)

    case :ets.lookup(tid, key) do
      [{^key, _, _, last_access}] -> :ets.delete(idx, {last_access, key})
      [] -> :ok
    end

    :ets.delete(tid, key)
    :ok
  end

  @doc """
  Removes every entry from the query cache.
  """
  @spec flush(atom(), String.t()) :: :ok
  def flush(name, tenant_id) do
    {tid, idx} = tables(name, tenant_id)
    :ets.delete_all_objects(tid)
    :ets.delete_all_objects(idx)
    :ok
  end

  @impl GenServer
  def init({name, tenant_id}) do
    tid = :ets.new(:query_cache, [:set, :public, read_concurrency: true, write_concurrency: true])

    idx =
      :ets.new(:query_cache_idx, [
        :ordered_set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    TenantRegistry.put_value(name, tenant_id, :qc_table, tid)
    TenantRegistry.put_value(name, tenant_id, :qc_table_idx, idx)
    schedule_sweep()
    {:ok, %{name: name, tenant_id: tenant_id, tid: tid, idx: idx}}
  end

  @impl GenServer
  def handle_info(:sweep, %{tid: tid, idx: idx} = state) do
    now = System.monotonic_time(:millisecond)

    expired =
      :ets.select(tid, [
        {{:"$1", :_, :"$2", :"$3"}, [{:is_integer, :"$2"}, {:<, :"$2", {:const, now}}],
         [{{:"$1", :"$3"}}]}
      ])

    Enum.each(expired, fn {key, last_access} ->
      :ets.delete(tid, key)
      :ets.delete(idx, {last_access, key})
    end)

    schedule_sweep()
    {:noreply, state}
  end

  defp tables(name, tenant_id) do
    {TenantRegistry.get_value(name, tenant_id, :qc_table),
     TenantRegistry.get_value(name, tenant_id, :qc_table_idx)}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
