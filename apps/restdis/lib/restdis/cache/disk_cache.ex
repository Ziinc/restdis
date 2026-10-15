defmodule Restdis.Cache.DiskCache do
  @moduledoc """
  FeoxDB-backed disk cache for persisted entries of a tenant.

  Keys and entries are stored as Erlang terms through `FeoxDB.Term`, which
  chunks values over FeoxDB's 4 MB record limit transparently. Writes reach
  disk in the background; the store is reopened (and its index rebuilt) when
  the process restarts, and closed in `terminate/2`.
  """

  use GenServer

  require Logger

  alias Restdis.Cache.InstanceConfig
  alias Restdis.Cache.Key
  alias Restdis.Cache.TenantRegistry

  @store_file "store.feox"
  @default_cap_bytes 500 * 1024 * 1024
  @block_size 4096
  @record_overhead 64

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
  Reads `key` from the tenant's FeoxDB store.

  Reads the store directly (rather than routing through the disk cache's own
  GenServer) since FeoxDB serves reads concurrently from any process; going
  through the GenServer would needlessly serialize every read behind
  whatever writes/evictions are in flight.
  """
  @spec get(atom(), String.t(), Key.t()) :: {:ok, term()} | :miss
  def get(name, tenant_id, key) do
    case TenantRegistry.get_value(name, tenant_id, :dc_store) do
      nil ->
        GenServer.call(TenantRegistry.via(name, tenant_id, :disk_cache), {:get, key})

      store ->
        case fetch_live(store, key) do
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
  @spec put(String.t(), Key.t(), term(), keyword()) :: :ok | {:error, FeoxDB.error_reason()}
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
  @spec set_persist(atom(), String.t(), Key.t(), boolean()) ::
          :ok | :not_found | {:error, FeoxDB.error_reason()}
  def set_persist(name, tenant_id, key, persist) do
    GenServer.call(TenantRegistry.via(name, tenant_id, :disk_cache), {:set_persist, key, persist})
  end

  @doc """
  Returns the metadata of `key` without reading its value.

  Reads the store directly for the same concurrency reason as `get/2`.
  """
  @spec peek_meta(atom(), String.t(), Key.t()) :: {:ok, %{persist: boolean()}} | :miss
  def peek_meta(name, tenant_id, key) do
    case TenantRegistry.get_value(name, tenant_id, :dc_store) do
      nil ->
        GenServer.call(TenantRegistry.via(name, tenant_id, :disk_cache), {:peek_meta, key})

      store ->
        fetch_meta(store, key)
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
  Returns the approximate on-disk footprint, in bytes, of the tenant's FeoxDB
  store.

  This is a running tally of the external term size of every live entry,
  rather than a raw file-size measurement: the store file is preallocated
  (sparse) at open, so its size says nothing about what it holds.
  """
  @spec disk_size_bytes(atom(), String.t()) :: non_neg_integer()
  def disk_size_bytes(name, tenant_id) do
    GenServer.call(TenantRegistry.via(name, tenant_id, :disk_cache), :disk_size_bytes)
  end

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    name = Keyword.fetch!(opts, :name)
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    data_dir = Keyword.fetch!(opts, :data_dir)
    tenant_dir = Path.join(data_dir, tenant_id)
    File.mkdir_p!(tenant_dir)

    store =
      FeoxDB.open!(
        path: Path.join(tenant_dir, @store_file),
        # Sparse file: only blocks actually written use disk.
        file_size: 2 * cap_bytes(name)
      )

    TenantRegistry.put_value(name, tenant_id, :dc_store, store)
    {bytes, persist_count, evict_idx, persist_keys} = rebuild_index(store)
    record_persist_count(name, tenant_id, persist_count)

    {:ok,
     %{
       store: store,
       name: name,
       tenant_id: tenant_id,
       tenant_dir: tenant_dir,
       bytes: bytes,
       evict_idx: evict_idx,
       persist_keys: persist_keys
     }}
  end

  @impl GenServer
  def terminate(_reason, %{store: store}) do
    FeoxDB.close(store)
  end

  @impl GenServer
  def handle_call({:get, key}, _from, %{store: store} = state) do
    case fetch_live(store, key) do
      {:ok, value, _expires_at} ->
        {:reply, {:ok, value}, state}

      :expired ->
        {:reply, :miss, expire_entry(key, state)}

      :miss ->
        {:reply, :miss, state}
    end
  end

  def handle_call({:get_with_ttl, key}, _from, %{store: store} = state) do
    case fetch_live(store, key) do
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

  def handle_call({:put, key, value, persist, expires_at}, _from, state) do
    entry =
      {:v1,
       %{
         value: value,
         persist: persist,
         inserted_at: System.monotonic_time(),
         expires_at: expires_at
       }}

    case write_entry(state, key, entry) do
      {:ok, state} -> {:reply, :ok, evict_over_cap(state)}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:set_persist, key, persist}, _from, %{store: store} = state) do
    case fetch(store, key) do
      {:ok, {:v1, meta}} ->
        case write_entry(state, key, {:v1, %{meta | persist: persist}}) do
          {:ok, state} -> {:reply, :ok, state}
          {:error, reason, state} -> {:reply, {:error, reason}, state}
        end

      :error ->
        {:reply, :not_found, state}
    end
  end

  def handle_call({:peek_meta, key}, _from, %{store: store} = state) do
    {:reply, fetch_meta(store, key), state}
  end

  def handle_call(:persisted_entries, _from, %{store: store, persist_keys: persist_keys} = state) do
    entries =
      Enum.flat_map(persist_keys, fn key ->
        case fetch(store, key) do
          {:ok, {:v1, %{value: value}}} -> [{key, value}]
          :error -> []
        end
      end)

    {:reply, entries, state}
  end

  def handle_call(:flush, _from, state) do
    state = Enum.reduce(indexed_keys(state), state, &drop_entry(&2, &1))
    {:reply, :ok, %{state | bytes: 0}}
  end

  def handle_call(:disk_size_bytes, _from, %{bytes: bytes} = state) do
    {:reply, bytes, state}
  end

  def handle_call(:count, _from, state) do
    {:reply, :gb_sets.size(state.evict_idx) + MapSet.size(state.persist_keys), state}
  end

  def handle_call({:delete, key}, _from, state) do
    {:reply, :ok, drop_entry(state, key)}
  end

  # On a failed write the key stays dropped, so a stale value is never served.
  defp write_entry(%{store: store} = state, key, {:v1, meta} = entry) do
    state = drop_entry(state, key)

    case FeoxDB.Term.put(store, key, entry) do
      :ok ->
        state = %{state | bytes: state.bytes + entry_size_of(key, entry)}
        {:ok, add_to_index(state, key, meta.persist, meta.inserted_at)}

      {:error, reason} ->
        Logger.warning(
          "disk cache write failed for tenant #{state.tenant_id}: #{inspect(reason)}"
        )

        {:error, reason, state}
    end
  end

  defp drop_entry(%{store: store} = state, key) do
    case fetch(store, key) do
      {:ok, entry} ->
        :ok = FeoxDB.Term.delete(store, key)
        state = remove_from_index(state, key, entry)
        %{state | bytes: max(state.bytes - entry_size_of(key, entry), 0)}

      :error ->
        state
    end
  end

  defp indexed_keys(%{evict_idx: evict_idx, persist_keys: persist_keys}) do
    Enum.map(:gb_sets.to_list(evict_idx), fn {_inserted_at, key} -> key end) ++
      MapSet.to_list(persist_keys)
  end

  defp fetch(store, key) do
    case FeoxDB.Term.get(store, key) do
      {:ok, entry} -> {:ok, entry}
      # `:closed` covers a direct read racing this process's terminate/2.
      {:error, _reason} -> :error
    end
  end

  defp fetch_live(store, key) do
    case fetch(store, key) do
      {:ok, {:v1, %{value: value, expires_at: expires_at}}} ->
        if expired?(expires_at), do: :expired, else: {:ok, value, expires_at}

      :error ->
        :miss
    end
  end

  defp expired?(:infinity), do: false
  defp expired?(expires_at), do: expires_at <= System.system_time(:millisecond)

  defp expire_entry(key, state), do: drop_entry(state, key)

  defp cap_bytes(name), do: InstanceConfig.get(name, :disk_cap_bytes, @default_cap_bytes)

  defp evict_over_cap(%{name: name, bytes: bytes} = state) do
    do_evict_over_cap(bytes, cap_bytes(name), state)
  end

  defp do_evict_over_cap(
         bytes,
         cap,
         %{store: store, tenant_id: tenant_id, evict_idx: evict_idx} = state
       ) do
    if bytes > cap and not :gb_sets.is_empty(evict_idx) do
      {{_inserted_at, evict_key}, rest_idx} = :gb_sets.take_smallest(evict_idx)
      evict_size = entry_size(store, evict_key)
      :ok = FeoxDB.Term.delete(store, evict_key)

      :telemetry.execute([:restdis, :cache, :disk_evict], %{count: 1}, %{
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

  defp add_to_index(%{persist_keys: persist_keys} = state, key, true, _inserted_at) do
    %{state | persist_keys: MapSet.put(persist_keys, key)}
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

  defp remove_from_index(state, key, {:v1, %{persist: false, inserted_at: inserted_at}}) do
    %{state | evict_idx: gb_sets_delete_any({inserted_at, key}, state.evict_idx)}
  end

  defp remove_from_index(state, key, {:v1, %{persist: true}}) do
    %{state | persist_keys: MapSet.delete(state.persist_keys, key)}
  end

  defp gb_sets_delete_any(element, set) do
    if :gb_sets.is_member(element, set) do
      :gb_sets.delete(element, set)
    else
      set
    end
  end

  defp fetch_meta(store, key) do
    case fetch(store, key) do
      {:ok, {:v1, %{persist: persist}}} -> {:ok, %{persist: persist}}
      :error -> :miss
    end
  end

  defp entry_size(store, key) do
    case fetch(store, key) do
      {:ok, entry} -> entry_size_of(key, entry)
      :error -> 0
    end
  end

  # FeoxDB allocates whole 4 KB blocks per record, so round up to track real disk use.
  defp entry_size_of(key, entry) do
    size = :erlang.external_size({key, entry}) + @record_overhead
    div(size + @block_size - 1, @block_size) * @block_size
  end

  defp rebuild_index(store) do
    store
    |> FeoxDB.Term.stream()
    |> Enum.reduce({0, 0, :gb_sets.empty(), MapSet.new()}, fn {key, entry},
                                                              {bytes, persist_count, evict_idx,
                                                               persist_keys} ->
      bytes = bytes + entry_size_of(key, entry)

      case entry do
        {:v1, %{persist: true}} ->
          {bytes, persist_count + 1, evict_idx, MapSet.put(persist_keys, key)}

        {:v1, %{persist: false, inserted_at: inserted_at}} ->
          {bytes, persist_count, :gb_sets.add({inserted_at, key}, evict_idx), persist_keys}
      end
    end)
  end

  defp record_persist_count(name, tenant_id, count) do
    ref = :counters.new(1, [:atomics])
    if count > 0, do: :counters.add(ref, 1, count)
    TenantRegistry.put_value(name, tenant_id, :qc_persist, ref)
  end
end
