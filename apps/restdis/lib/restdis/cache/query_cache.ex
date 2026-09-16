defmodule Restdis.Cache.QueryCache do
  @moduledoc """
  Per-tenant ETS query cache holding cached PostgREST responses and their TTLs.
  """

  use GenServer

  alias Restdis.Cache.Key
  alias Restdis.Cache.TenantRegistry

  @sweep_interval_ms 30_000

  @doc """
  Returns the child spec of the query cache for `tenant_id`.
  """
  @spec child_spec(String.t()) :: Supervisor.child_spec()
  def child_spec(tenant_id) do
    %{
      id: {__MODULE__, tenant_id},
      start: {__MODULE__, :start_link, [tenant_id]},
      type: :worker,
      restart: :permanent
    }
  end

  @doc """
  Starts the query cache for `tenant_id`.
  """
  @spec start_link(String.t()) :: GenServer.on_start()
  def start_link(tenant_id) do
    GenServer.start_link(__MODULE__, tenant_id, name: TenantRegistry.via(tenant_id, :query_cache))
  end

  @default_ets_cap_bytes 500 * 1024 * 1024

  @doc """
  Reads `key`, treating an expired entry as a miss.
  """
  @spec get(String.t(), Key.t()) :: {:ok, term()} | :miss
  def get(tenant_id, key) do
    {tid, idx} = tables(tenant_id)
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
  Writes `value` under `key`, expiring it after `opts[:ttl_ms]`.

  Enforces the per-tenant ETS memory cap (`Application.get_env(:restdis, :ets_cap_bytes)`,
  defaulting to 500 MB) by evicting the least-recently-used entries when the
  write pushes the tenant's table over the cap.
  """
  @spec put(String.t(), Key.t(), term(), keyword()) :: :ok
  def put(tenant_id, key, value, opts \\ []) do
    {tid, idx} = tables(tenant_id)

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
    evict_over_cap(tenant_id, tid, idx)
    :ok
  end

  @doc """
  Returns the approximate memory footprint, in bytes, of the tenant's ETS
  query cache table.
  """
  @spec memory_bytes(String.t()) :: non_neg_integer()
  def memory_bytes(tenant_id) do
    {tid, _idx} = tables(tenant_id)
    :ets.info(tid, :memory) * :erlang.system_info(:wordsize)
  end

  defp touch(tid, idx, key, old_last_access) do
    new_last_access = System.monotonic_time()
    :ets.delete(idx, {old_last_access, key})
    :ets.insert(idx, {{new_last_access, key}})
    :ets.update_element(tid, key, {4, new_last_access})
  end

  defp evict_over_cap(tenant_id, tid, idx) do
    cap = Application.get_env(:restdis, :ets_cap_bytes, @default_ets_cap_bytes)
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
  @spec delete(String.t(), Key.t()) :: :ok
  def delete(tenant_id, key) do
    {tid, idx} = tables(tenant_id)

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
  @spec flush(String.t()) :: :ok
  def flush(tenant_id) do
    {tid, idx} = tables(tenant_id)
    :ets.delete_all_objects(tid)
    :ets.delete_all_objects(idx)
    :ok
  end

  @impl GenServer
  def init(tenant_id) do
    tid = :ets.new(:query_cache, [:set, :public, read_concurrency: true, write_concurrency: true])

    idx =
      :ets.new(:query_cache_idx, [
        :ordered_set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    :persistent_term.put({:sc_qc, tenant_id}, tid)
    :persistent_term.put({:sc_qc_idx, tenant_id}, idx)
    schedule_sweep()
    {:ok, %{tenant_id: tenant_id, tid: tid, idx: idx}}
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

  @impl GenServer
  def terminate(_reason, %{tenant_id: tenant_id}) do
    :persistent_term.erase({:sc_qc, tenant_id})
    :persistent_term.erase({:sc_qc_idx, tenant_id})
    :persistent_term.erase({:sc_persist, tenant_id})
  end

  defp tables(tenant_id) do
    {:persistent_term.get({:sc_qc, tenant_id}), :persistent_term.get({:sc_qc_idx, tenant_id})}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
