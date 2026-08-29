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
    tid = table(tenant_id)
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(tid, key) do
      [{^key, value, :infinity, _last_access}] ->
        touch(tid, key)
        {:ok, value}

      [{^key, value, expires_at, _last_access}] when expires_at > now ->
        touch(tid, key)
        {:ok, value}

      [{^key, _, _, _}] ->
        :ets.delete(tid, key)
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
    tid = table(tenant_id)

    expires_at =
      case opts[:ttl_ms] do
        nil -> :infinity
        ms -> System.monotonic_time(:millisecond) + ms
      end

    :ets.insert(tid, {key, value, expires_at, System.monotonic_time()})
    evict_over_cap(tenant_id, tid)
    :ok
  end

  @doc """
  Returns the approximate memory footprint, in bytes, of the tenant's ETS
  query cache table.
  """
  @spec memory_bytes(String.t()) :: non_neg_integer()
  def memory_bytes(tenant_id) do
    tid = table(tenant_id)
    :ets.info(tid, :memory) * :erlang.system_info(:wordsize)
  end

  defp touch(tid, key) do
    :ets.update_element(tid, key, {4, System.monotonic_time()})
  end

  defp evict_over_cap(tenant_id, tid) do
    cap = Application.get_env(:restdis, :ets_cap_bytes, @default_ets_cap_bytes)
    do_evict_over_cap(tenant_id, tid, cap)
  end

  defp do_evict_over_cap(tenant_id, tid, cap) do
    mem_bytes = :ets.info(tid, :memory) * :erlang.system_info(:wordsize)

    if mem_bytes > cap do
      case oldest_entry(tid) do
        nil ->
          :ok

        lru_key ->
          :ets.delete(tid, lru_key)

          :telemetry.execute([:restdis, :cache, :ets_evict], %{count: 1}, %{
            tenant_id: tenant_id,
            key: lru_key
          })

          do_evict_over_cap(tenant_id, tid, cap)
      end
    else
      :ok
    end
  end

  defp oldest_entry(tid) do
    :ets.foldl(
      fn {key, _value, _expires_at, last_access}, acc ->
        case acc do
          nil -> {key, last_access}
          {_, acc_last_access} when last_access < acc_last_access -> {key, last_access}
          _ -> acc
        end
      end,
      nil,
      tid
    )
    |> case do
      nil -> nil
      {key, _last_access} -> key
    end
  end

  @doc """
  Removes `key` from the query cache.
  """
  @spec delete(String.t(), Key.t()) :: :ok
  def delete(tenant_id, key) do
    :ets.delete(table(tenant_id), key)
    :ok
  end

  @doc """
  Removes every entry from the query cache.
  """
  @spec flush(String.t()) :: :ok
  def flush(tenant_id) do
    :ets.delete_all_objects(table(tenant_id))
    :ok
  end

  @impl GenServer
  def init(tenant_id) do
    tid = :ets.new(:query_cache, [:set, :public, read_concurrency: true, write_concurrency: true])
    :persistent_term.put({:sc_qc, tenant_id}, tid)
    ref = :counters.new(1, [:atomics])
    :persistent_term.put({:sc_persist, tenant_id}, ref)
    schedule_sweep()
    {:ok, %{tenant_id: tenant_id, tid: tid}}
  end

  @impl GenServer
  def handle_info(:sweep, %{tid: tid} = state) do
    now = System.monotonic_time(:millisecond)

    :ets.select_delete(tid, [
      {{:_, :_, :"$1", :_}, [{:is_integer, :"$1"}, {:<, :"$1", {:const, now}}], [true]}
    ])

    schedule_sweep()
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, %{tenant_id: tenant_id}) do
    :persistent_term.erase({:sc_qc, tenant_id})
    :persistent_term.erase({:sc_persist, tenant_id})
  end

  defp table(tenant_id), do: :persistent_term.get({:sc_qc, tenant_id})

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
