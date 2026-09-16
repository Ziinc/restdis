defmodule Restdis.Cache.DiskCache do
  @moduledoc """
  CubDB-backed disk cache for persisted entries of a tenant.
  """

  use GenServer

  alias Restdis.Cache.InstanceConfig
  alias Restdis.Cache.Key
  alias Restdis.Cache.TenantRegistry

  @doc """
  Starts the disk cache for the tenant given in `opts` (`:name`, `:tenant_id`, `:data_dir`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    GenServer.start_link(__MODULE__, opts, name: TenantRegistry.via(name, tenant_id, :disk_cache))
  end

  @doc """
  Reads `key` from the tenant's CubDB store.

  Calls the CubDB process directly (rather than routing through the disk
  cache's own GenServer) since CubDB already serves reads concurrently from
  any process; going through the GenServer would needlessly serialize every
  read behind whatever writes/evictions are in flight.
  """
  @spec get(atom(), String.t(), Key.t()) :: {:ok, term()} | :miss
  def get(name, tenant_id, key) do
    case TenantRegistry.get_value(name, tenant_id, :dc_cubdb) do
      nil ->
        GenServer.call(TenantRegistry.via(name, tenant_id, :disk_cache), {:get, key})

      cubdb ->
        case fetch_live(cubdb, key) do
          {:ok, value, _expires_at} ->
            {:ok, value}

          :expired ->
            # Falls back so the removal goes through the process owning `state.bytes`.
            GenServer.call(TenantRegistry.via(name, tenant_id, :disk_cache), {:get, key})

          :miss ->
            :miss
        end
    end
  end

  @doc """
  Writes `value` under `key`, persisting it when `opts[:persist]` is true and
  expiring it after `opts[:ttl_ms]`, if given. `opts[:name]` selects the
  cache instance (required).
  """
  @spec put(String.t(), Key.t(), term(), keyword()) :: :ok
  def put(tenant_id, key, value, opts \\ []) do
    name = Keyword.fetch!(opts, :name)
    persist = Keyword.get(opts, :persist, false)

    expires_at =
      case opts[:ttl_ms] do
        nil -> :infinity
        ms -> System.system_time(:millisecond) + ms
      end

    GenServer.call(
      TenantRegistry.via(name, tenant_id, :disk_cache),
      {:put, key, value, persist, expires_at}
    )
  end

  @doc """
  Reads `key`, returning its remaining ttl in milliseconds (or `nil` when the
  entry carries no ttl) alongside its value. Treats an expired entry as a
  miss, the same as `get/2`.
  """
  @spec get_with_ttl(atom(), String.t(), Key.t()) :: {:ok, term(), pos_integer() | nil} | :miss
  def get_with_ttl(name, tenant_id, key) do
    GenServer.call(TenantRegistry.via(name, tenant_id, :disk_cache), {:get_with_ttl, key})
  end

  @doc """
  Flips the persist flag of an existing entry.
  """
  @spec set_persist(atom(), String.t(), Key.t(), boolean()) :: :ok | :not_found
  def set_persist(name, tenant_id, key, persist) do
    GenServer.call(TenantRegistry.via(name, tenant_id, :disk_cache), {:set_persist, key, persist})
  end

  @doc """
  Returns the metadata of `key` without reading its value.

  Calls the CubDB process directly for the same concurrency reason as
  `get/2`.
  """
  @spec peek_meta(atom(), String.t(), Key.t()) :: {:ok, %{persist: boolean()}} | :miss
  def peek_meta(name, tenant_id, key) do
    case TenantRegistry.get_value(name, tenant_id, :dc_cubdb) do
      nil ->
        GenServer.call(TenantRegistry.via(name, tenant_id, :disk_cache), {:peek_meta, key})

      cubdb ->
        fetch_meta(cubdb, key)
    end
  end

  @doc """
  Removes `key` from the disk cache.

  Synchronous (a `call`, not a `cast`) so a caller that deletes a key and
  then immediately reads or recreates it elsewhere — e.g. a supervising
  process that stops some other stateful process depending on this key and
  then lets a later re-hydration step read from disk — cannot observe the
  pre-delete value. A `cast` here previously let the delete's message race
  a subsequent `get` call from a different process, since Erlang only
  orders messages between the same sender and receiver.
  """
  @spec delete(atom(), String.t(), Key.t()) :: :ok
  def delete(name, tenant_id, key) do
    GenServer.call(TenantRegistry.via(name, tenant_id, :disk_cache), {:delete, key})
  end

  @doc """
  Returns the `{key, value}` pairs flagged `persist` for the tenant.
  """
  @spec persisted_entries(atom(), String.t()) :: [{Key.t(), term()}]
  def persisted_entries(name, tenant_id) do
    case TenantRegistry.whereis(name, tenant_id, :disk_cache) do
      nil -> []
      pid -> GenServer.call(pid, :persisted_entries)
    end
  end

  @doc """
  Removes every entry from the tenant's disk cache.
  """
  @spec flush(atom(), String.t()) :: :ok
  def flush(name, tenant_id) do
    GenServer.call(TenantRegistry.via(name, tenant_id, :disk_cache), :flush)
  end

  @doc """
  Returns the number of entries held in the tenant's disk cache.
  """
  @spec count(atom(), String.t()) :: non_neg_integer()
  def count(name, tenant_id) do
    GenServer.call(TenantRegistry.via(name, tenant_id, :disk_cache), :count)
  end

  @doc """
  Returns the approximate on-disk footprint, in bytes, of the tenant's CubDB
  store.

  This is a running tally of the external term size of every live entry,
  rather than a raw file-size measurement: CubDB's log-structured storage
  only shrinks the underlying file on (asynchronous) compaction, which would
  make cap enforcement based on `File.stat/1` sizes lag behind evictions.
  """
  @spec disk_size_bytes(atom(), String.t()) :: non_neg_integer()
  def disk_size_bytes(name, tenant_id) do
    GenServer.call(TenantRegistry.via(name, tenant_id, :disk_cache), :disk_size_bytes)
  end

  @impl GenServer
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    data_dir = Keyword.fetch!(opts, :data_dir)
    tenant_dir = Path.join(data_dir, tenant_id)
    File.mkdir_p!(tenant_dir)
    {:ok, cubdb} = CubDB.start_link(data_dir: tenant_dir)
    TenantRegistry.put_value(name, tenant_id, :dc_cubdb, cubdb)
    {bytes, persist_count, evict_idx, persist_keys} = rebuild_index(cubdb)
    record_persist_count(name, tenant_id, persist_count)

    {:ok,
     %{
       cubdb: cubdb,
       name: name,
       tenant_id: tenant_id,
       tenant_dir: tenant_dir,
       bytes: bytes,
       evict_idx: evict_idx,
       persist_keys: persist_keys
     }}
  end

  @impl GenServer
  def handle_call({:get, key}, _from, %{cubdb: cubdb} = state) do
    case fetch_live(cubdb, key) do
      {:ok, value, _expires_at} ->
        {:reply, {:ok, value}, state}

      :expired ->
        {:reply, :miss, expire_entry(key, state)}

      :miss ->
        {:reply, :miss, state}
    end
  end

  def handle_call({:get_with_ttl, key}, _from, %{cubdb: cubdb} = state) do
    case fetch_live(cubdb, key) do
      {:ok, value, :infinity} ->
        {:reply, {:ok, value, nil}, state}

      {:ok, value, expires_at} ->
        {:reply, {:ok, value, expires_at - System.system_time(:millisecond)}, state}

      :expired ->
        {:reply, :miss, expire_entry(key, state)}

      :miss ->
        {:reply, :miss, state}
    end
  end

  def handle_call({:put, key, value, persist, expires_at}, _from, %{cubdb: cubdb} = state) do
    inserted_at = System.monotonic_time()

    entry =
      {:v1,
       %{
         value: value,
         persist: persist,
         inserted_at: inserted_at,
         expires_at: expires_at
       }}

    old_size = entry_size(cubdb, key)
    state = remove_from_index(state, key)
    :ok = CubDB.put(cubdb, key, entry)
    state = %{state | bytes: state.bytes - old_size + entry_size_of(key, entry)}
    state = add_to_index(state, key, persist, inserted_at)
    state = evict_over_cap(state)
    {:reply, :ok, state}
  end

  def handle_call({:set_persist, key, persist}, _from, %{cubdb: cubdb} = state) do
    old_size = entry_size(cubdb, key)

    case CubDB.fetch(cubdb, key) do
      {:ok, {:v1, %{value: value} = meta}} ->
        inserted_at = Map.get(meta, :inserted_at, 0)
        new_meta = Map.merge(meta, %{value: value, persist: persist})
        new_entry = {:v1, new_meta}
        state = remove_from_index(state, key)
        :ok = CubDB.put(cubdb, key, new_entry)
        state = %{state | bytes: state.bytes - old_size + entry_size_of(key, new_entry)}
        state = add_to_index(state, key, persist, inserted_at)
        {:reply, :ok, state}

      {:ok, value} ->
        inserted_at = System.monotonic_time()

        new_entry =
          {:v1,
           %{
             value: value,
             persist: persist,
             inserted_at: inserted_at,
             expires_at: :infinity
           }}

        state = remove_from_index(state, key)
        :ok = CubDB.put(cubdb, key, new_entry)
        state = %{state | bytes: state.bytes - old_size + entry_size_of(key, new_entry)}
        state = add_to_index(state, key, persist, inserted_at)
        {:reply, :ok, state}

      :error ->
        {:reply, :not_found, state}
    end
  end

  def handle_call({:peek_meta, key}, _from, %{cubdb: cubdb} = state) do
    {:reply, fetch_meta(cubdb, key), state}
  end

  def handle_call(:persisted_entries, _from, %{cubdb: cubdb, persist_keys: persist_keys} = state) do
    entries =
      persist_keys
      |> Enum.flat_map(fn key ->
        case CubDB.fetch(cubdb, key) do
          {:ok, {:v1, %{value: value}}} -> [{key, value}]
          _ -> []
        end
      end)

    {:reply, entries, state}
  end

  def handle_call(:flush, _from, %{cubdb: cubdb} = state) do
    CubDB.clear(cubdb)

    {:reply, :ok, %{state | bytes: 0, evict_idx: :gb_sets.empty(), persist_keys: MapSet.new()}}
  end

  def handle_call(:disk_size_bytes, _from, %{bytes: bytes} = state) do
    {:reply, bytes, state}
  end

  def handle_call(:count, _from, %{cubdb: cubdb} = state) do
    {:reply, CubDB.size(cubdb), state}
  end

  @impl GenServer
  def handle_call({:delete, key}, _from, %{cubdb: cubdb} = state) do
    old_size = entry_size(cubdb, key)
    state = remove_from_index(state, key)
    CubDB.delete(cubdb, key)
    {:reply, :ok, %{state | bytes: max(state.bytes - old_size, 0)}}
  end

  defp fetch_live(cubdb, key) do
    case CubDB.fetch(cubdb, key) do
      {:ok, {:v1, %{value: value} = meta}} ->
        expires_at = Map.get(meta, :expires_at, :infinity)

        if expired?(expires_at) do
          :expired
        else
          {:ok, value, expires_at}
        end

      {:ok, value} ->
        {:ok, value, :infinity}

      :error ->
        :miss
    end
  end

  defp expired?(:infinity), do: false
  defp expired?(expires_at), do: expires_at <= System.system_time(:millisecond)

  defp expire_entry(key, %{cubdb: cubdb} = state) do
    old_size = entry_size(cubdb, key)
    state = remove_from_index(state, key)
    CubDB.delete(cubdb, key)
    %{state | bytes: max(state.bytes - old_size, 0)}
  end

  defp evict_over_cap(%{name: name, bytes: bytes} = state) do
    cap = InstanceConfig.get(name, :cubdb_cap_bytes, 500 * 1024 * 1024)
    do_evict_over_cap(bytes, cap, state)
  end

  defp do_evict_over_cap(
         bytes,
         cap,
         %{cubdb: cubdb, tenant_id: tenant_id, evict_idx: evict_idx} = state
       ) do
    if bytes > cap and not :gb_sets.is_empty(evict_idx) do
      {{_inserted_at, evict_key}, rest_idx} = :gb_sets.take_smallest(evict_idx)
      evict_size = entry_size(cubdb, evict_key)
      CubDB.delete(cubdb, evict_key)

      :telemetry.execute([:restdis, :cache, :cubdb_evict], %{count: 1}, %{
        tenant_id: tenant_id,
        key: evict_key
      })

      new_bytes = max(bytes - evict_size, 0)
      state = %{state | evict_idx: rest_idx}
      do_evict_over_cap(new_bytes, cap, state)
    else
      %{state | bytes: bytes}
    end
  end

  defp add_to_index(
         %{evict_idx: evict_idx, persist_keys: persist_keys} = state,
         key,
         true,
         _inserted_at
       ) do
    %{state | persist_keys: MapSet.put(persist_keys, key), evict_idx: evict_idx}
  end

  defp add_to_index(
         %{evict_idx: evict_idx, persist_keys: persist_keys} = state,
         key,
         false,
         inserted_at
       ) do
    %{
      state
      | evict_idx: :gb_sets.add({inserted_at, key}, evict_idx),
        persist_keys: MapSet.delete(persist_keys, key)
    }
  end

  defp remove_from_index(
         %{cubdb: cubdb, evict_idx: evict_idx, persist_keys: persist_keys} = state,
         key
       ) do
    case CubDB.fetch(cubdb, key) do
      {:ok, {:v1, %{persist: false} = meta}} ->
        inserted_at = Map.get(meta, :inserted_at, 0)
        %{state | evict_idx: gb_sets_delete_any({inserted_at, key}, evict_idx)}

      {:ok, {:v1, %{persist: true}}} ->
        %{state | persist_keys: MapSet.delete(persist_keys, key)}

      _ ->
        state
    end
  end

  defp gb_sets_delete_any(element, set) do
    if :gb_sets.is_member(element, set) do
      :gb_sets.delete(element, set)
    else
      set
    end
  end

  defp fetch_meta(cubdb, key) do
    case CubDB.fetch(cubdb, key) do
      {:ok, {:v1, %{persist: persist}}} -> {:ok, %{persist: persist}}
      {:ok, _} -> {:ok, %{persist: false}}
      :error -> :miss
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

  defp rebuild_index(cubdb) do
    cubdb
    |> CubDB.select()
    |> Enum.reduce({0, 0, :gb_sets.empty(), MapSet.new()}, fn {key, entry},
                                                              {bytes, persist_count, evict_idx,
                                                               persist_keys} ->
      bytes = bytes + entry_size_of(key, entry)

      case entry do
        {:v1, %{persist: true}} ->
          {bytes, persist_count + 1, evict_idx, MapSet.put(persist_keys, key)}

        {:v1, %{persist: false} = meta} ->
          inserted_at = Map.get(meta, :inserted_at, 0)
          {bytes, persist_count, :gb_sets.add({inserted_at, key}, evict_idx), persist_keys}

        _ ->
          {bytes, persist_count, evict_idx, persist_keys}
      end
    end)
  end

  defp record_persist_count(name, tenant_id, count) do
    ref = :counters.new(1, [:atomics])
    if count > 0, do: :counters.add(ref, 1, count)
    TenantRegistry.put_value(name, tenant_id, :qc_persist, ref)
  end
end
