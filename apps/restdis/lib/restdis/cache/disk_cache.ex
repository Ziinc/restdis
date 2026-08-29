defmodule Restdis.Cache.DiskCache do
  @moduledoc """
  CubDB-backed disk cache for persisted entries of a tenant.
  """

  use GenServer

  alias Restdis.Cache.Key
  alias Restdis.Cache.TenantRegistry

  @default_cubdb_cap_bytes 500 * 1024 * 1024

  @doc """
  Starts the disk cache for the tenant given in `opts`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    GenServer.start_link(__MODULE__, opts, name: TenantRegistry.via(tenant_id, :disk_cache))
  end

  @doc """
  Reads `key` from the tenant's CubDB store.
  """
  @spec get(String.t(), Key.t()) :: {:ok, term()} | :miss
  def get(tenant_id, key) do
    GenServer.call(TenantRegistry.via(tenant_id, :disk_cache), {:get, key})
  end

  @doc """
  Writes `value` under `key`, persisting it when `opts[:persist]` is true.
  """
  @spec put(String.t(), Key.t(), term(), keyword()) :: :ok
  def put(tenant_id, key, value, opts \\ []) do
    persist = Keyword.get(opts, :persist, false)
    GenServer.call(TenantRegistry.via(tenant_id, :disk_cache), {:put, key, value, persist})
  end

  @doc """
  Flips the persist flag of an existing entry.
  """
  @spec set_persist(String.t(), Key.t(), boolean()) :: :ok | :not_found
  def set_persist(tenant_id, key, persist) do
    GenServer.call(TenantRegistry.via(tenant_id, :disk_cache), {:set_persist, key, persist})
  end

  @doc """
  Returns the metadata of `key` without reading its value.
  """
  @spec peek_meta(String.t(), Key.t()) :: {:ok, %{persist: boolean()}} | :miss
  def peek_meta(tenant_id, key) do
    GenServer.call(TenantRegistry.via(tenant_id, :disk_cache), {:peek_meta, key})
  end

  @doc """
  Removes `key` from the disk cache.
  """
  @spec delete(String.t(), Key.t()) :: :ok
  def delete(tenant_id, key) do
    GenServer.cast(TenantRegistry.via(tenant_id, :disk_cache), {:delete, key})
  end

  @doc """
  Returns the `{key, value}` pairs flagged `persist` for the tenant.
  """
  @spec persisted_entries(String.t()) :: [{Key.t(), term()}]
  def persisted_entries(tenant_id) do
    case TenantRegistry.whereis(tenant_id, :disk_cache) do
      nil -> []
      pid -> GenServer.call(pid, :persisted_entries)
    end
  end

  @doc """
  Removes every entry from the tenant's disk cache.
  """
  @spec flush(String.t()) :: :ok
  def flush(tenant_id) do
    GenServer.call(TenantRegistry.via(tenant_id, :disk_cache), :flush)
  end

  @doc """
  Returns the approximate on-disk footprint, in bytes, of the tenant's CubDB
  store.

  This is a running tally of the external term size of every live entry,
  rather than a raw file-size measurement: CubDB's log-structured storage
  only shrinks the underlying file on (asynchronous) compaction, which would
  make cap enforcement based on `File.stat/1` sizes lag behind evictions.
  """
  @spec disk_size_bytes(String.t()) :: non_neg_integer()
  def disk_size_bytes(tenant_id) do
    GenServer.call(TenantRegistry.via(tenant_id, :disk_cache), :disk_size_bytes)
  end

  @impl GenServer
  def init(opts) do
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    data_dir = Keyword.fetch!(opts, :data_dir)
    tenant_dir = Path.join(data_dir, tenant_id)
    File.mkdir_p!(tenant_dir)
    {:ok, cubdb} = CubDB.start_link(data_dir: tenant_dir)
    recount_persist(tenant_id, cubdb)
    bytes = recount_bytes(cubdb)
    {:ok, %{cubdb: cubdb, tenant_id: tenant_id, tenant_dir: tenant_dir, bytes: bytes}}
  end

  @impl GenServer
  def handle_call({:get, key}, _from, %{cubdb: cubdb} = state) do
    result =
      case CubDB.fetch(cubdb, key) do
        {:ok, {:v1, %{value: value}}} -> {:ok, value}
        {:ok, value} -> {:ok, value}
        :error -> :miss
      end

    {:reply, result, state}
  end

  def handle_call({:put, key, value, persist}, _from, %{cubdb: cubdb} = state) do
    entry = {:v1, %{value: value, persist: persist, inserted_at: System.monotonic_time()}}
    old_size = entry_size(cubdb, key)
    :ok = CubDB.put(cubdb, key, entry)
    state = %{state | bytes: state.bytes - old_size + entry_size_of(key, entry)}
    state = evict_over_cap(state)
    {:reply, :ok, state}
  end

  def handle_call({:set_persist, key, persist}, _from, %{cubdb: cubdb} = state) do
    old_size = entry_size(cubdb, key)

    case CubDB.fetch(cubdb, key) do
      {:ok, {:v1, %{value: value} = meta}} ->
        new_meta = Map.merge(meta, %{value: value, persist: persist})
        new_entry = {:v1, new_meta}
        :ok = CubDB.put(cubdb, key, new_entry)
        state = %{state | bytes: state.bytes - old_size + entry_size_of(key, new_entry)}
        {:reply, :ok, state}

      {:ok, value} ->
        new_entry = {:v1, %{value: value, persist: persist, inserted_at: System.monotonic_time()}}
        :ok = CubDB.put(cubdb, key, new_entry)
        state = %{state | bytes: state.bytes - old_size + entry_size_of(key, new_entry)}
        {:reply, :ok, state}

      :error ->
        {:reply, :not_found, state}
    end
  end

  def handle_call({:peek_meta, key}, _from, %{cubdb: cubdb} = state) do
    result =
      case CubDB.fetch(cubdb, key) do
        {:ok, {:v1, %{persist: persist}}} -> {:ok, %{persist: persist}}
        {:ok, _} -> {:ok, %{persist: false}}
        :error -> :miss
      end

    {:reply, result, state}
  end

  def handle_call(:persisted_entries, _from, %{cubdb: cubdb} = state) do
    entries =
      cubdb
      |> CubDB.select()
      |> Stream.filter(&match?({_key, {:v1, %{persist: true}}}, &1))
      |> Enum.map(fn {key, {:v1, %{value: value}}} -> {key, value} end)

    {:reply, entries, state}
  end

  def handle_call(:flush, _from, %{cubdb: cubdb} = state) do
    CubDB.clear(cubdb)
    {:reply, :ok, %{state | bytes: 0}}
  end

  def handle_call(:disk_size_bytes, _from, %{bytes: bytes} = state) do
    {:reply, bytes, state}
  end

  @impl GenServer
  def handle_cast({:delete, key}, %{cubdb: cubdb} = state) do
    old_size = entry_size(cubdb, key)
    CubDB.delete(cubdb, key)
    {:noreply, %{state | bytes: max(state.bytes - old_size, 0)}}
  end

  defp evict_over_cap(%{cubdb: cubdb, tenant_id: tenant_id, bytes: bytes} = state) do
    cap = Application.get_env(:restdis, :cubdb_cap_bytes, @default_cubdb_cap_bytes)
    do_evict_over_cap(cubdb, tenant_id, bytes, cap, state)
  end

  defp do_evict_over_cap(cubdb, tenant_id, bytes, cap, state) do
    if bytes > cap do
      case oldest_non_persist_key(cubdb) do
        nil ->
          %{state | bytes: bytes}

        evict_key ->
          evict_size = entry_size(cubdb, evict_key)
          CubDB.delete(cubdb, evict_key)

          :telemetry.execute([:restdis, :cache, :cubdb_evict], %{count: 1}, %{
            tenant_id: tenant_id,
            key: evict_key
          })

          new_bytes = max(bytes - evict_size, 0)
          do_evict_over_cap(cubdb, tenant_id, new_bytes, cap, state)
      end
    else
      %{state | bytes: bytes}
    end
  end

  defp oldest_non_persist_key(cubdb) do
    cubdb
    |> CubDB.select()
    |> Stream.filter(fn
      {_key, {:v1, %{persist: false}}} -> true
      _ -> false
    end)
    |> Enum.min_by(
      fn {_key, {:v1, meta}} -> Map.get(meta, :inserted_at, 0) end,
      fn -> nil end
    )
    |> case do
      nil -> nil
      {key, _value} -> key
    end
  end

  defp entry_size(cubdb, key) do
    case CubDB.fetch(cubdb, key) do
      {:ok, entry} -> entry_size_of(key, entry)
      :error -> 0
    end
  end

  defp entry_size_of(key, entry) do
    :erlang.external_size({key, entry})
  end

  defp recount_bytes(cubdb) do
    cubdb
    |> CubDB.select()
    |> Enum.reduce(0, fn {key, entry}, acc -> acc + entry_size_of(key, entry) end)
  end

  defp recount_persist(tenant_id, cubdb) do
    count =
      CubDB.select(cubdb)
      |> Stream.filter(fn {_k, v} ->
        match?({:v1, %{persist: true}}, v)
      end)
      |> Enum.count()

    if count > 0 do
      ref = :persistent_term.get({:sc_persist, tenant_id})
      :counters.add(ref, 1, count)
    end
  end
end
