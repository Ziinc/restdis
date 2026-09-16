defmodule Restdis.Cache do
  @moduledoc """
  Public API of the cache bounded context: get, put, delete, peek and table flushes.

  Every function takes the cache instance's `name` as an optional, trailing
  argument, defaulting to `__MODULE__`, so a second instance mounted with a
  different `:name` (see `Restdis.Cache.Supervisor.start_link/1`) can be
  addressed without colliding with the default one.
  """

  alias Restdis.Cache.DiskCache
  alias Restdis.Cache.HotCache
  alias Restdis.Cache.InstanceConfig
  alias Restdis.Cache.Key
  alias Restdis.Cache.QueryCache
  alias Restdis.Cache.Replication
  alias Restdis.Cache.ReverseIndex
  alias Restdis.Cache.TenantId
  alias Restdis.Cache.TenantRegistry
  alias Restdis.Cache.TenantSupervisor

  @type tenant_id :: String.t()
  @type primary_key :: term()

  # Fallback for callers that omit `persist_cap:`; in-tree callers thread the tenant's actual cap instead.
  @default_persist_cap 50_000

  @doc """
  Child spec mounting the cache's supervision tree in a host's own
  supervisor, e.g. `{Restdis.Cache, data_dir: ..., origin: ..., repo: ...}`.

  `:restdis` declares no `mod:` application callback, so depending on it
  starts no processes; a host must mount this explicitly.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.get(opts, :name, __MODULE__)},
      start: {Restdis.Cache.Supervisor, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc """
  Reads `key`, falling back from the query cache to the disk cache to the origin.
  """
  @spec get(tenant_id(), Key.t(), atom()) :: {:ok, term()} | :miss
  def get(tenant_id, key, name \\ __MODULE__) do
    TenantId.cast!(tenant_id)
    TenantSupervisor.ensure_started(name, tenant_id)

    with :miss <- QueryCache.get(name, tenant_id, key),
         :miss <- disk_get_and_promote(name, tenant_id, key) do
      origin_fetch(name, tenant_id, key)
    end
  end

  @doc """
  Writes `value` under `key`. Pass `:ttl_ms` and `:persist` in `opts`.
  """
  @spec put(tenant_id(), Key.t(), term(), keyword(), atom()) :: :ok | {:error, :persist_cap}
  def put(tenant_id, key, value, opts \\ [], name \\ __MODULE__) do
    TenantId.cast!(tenant_id)
    TenantSupervisor.ensure_started(name, tenant_id)

    case do_put(tenant_id, key, value, opts) do
      :ok ->
        HotCache.delete(tenant_id, key)
        :ok

      error ->
        error
    end
  end

  @doc """
  Removes `key` from every cache layer and from the reverse index.

  Pass `replicated: true` in `opts` to apply a peer's delete without
  re-broadcasting it.
  """
  @spec delete(tenant_id(), Key.t(), keyword(), atom()) :: :ok
  def delete(tenant_id, key, opts \\ [], name \\ __MODULE__) do
    TenantId.cast!(tenant_id)
    TenantSupervisor.ensure_started(name, tenant_id)

    case DiskCache.peek_meta(name, tenant_id, key) do
      {:ok, %{persist: true}} ->
        decrement_persist(name, tenant_id)
        maybe_broadcast(opts, name, tenant_id, {:delete, key})

      _ ->
        :ok
    end

    QueryCache.delete(name, tenant_id, key)
    DiskCache.delete(name, tenant_id, key)
    ReverseIndex.purge_key(name, tenant_id, key)
    HotCache.delete(tenant_id, key)
    :ok
  end

  @doc """
  Stops the tenant aggregate and deletes its on-disk data.
  """
  @spec flush_tenant(tenant_id(), atom()) :: :ok
  def flush_tenant(tenant_id, name \\ __MODULE__) do
    TenantId.cast!(tenant_id)

    case TenantRegistry.whereis(name, tenant_id, :tenant) do
      nil -> :ok
      pid -> Supervisor.stop(pid, :normal)
    end

    data_dir = InstanceConfig.fetch!(name).data_dir
    tenant_dir = Path.join(data_dir, tenant_id)
    if File.exists?(tenant_dir), do: File.rm_rf!(tenant_dir)
    :ok
  end

  @doc """
  Invalidates every cache key that depends on `table`.
  """
  @spec flush_table(tenant_id(), String.t(), atom()) :: :ok
  def flush_table(tenant_id, table, name \\ __MODULE__) do
    TenantId.cast!(tenant_id)

    case TenantRegistry.whereis(name, tenant_id, :reverse_index) do
      nil ->
        :ok

      _ ->
        cache_keys = ReverseIndex.purge_table(name, tenant_id, table)

        Enum.each(cache_keys, fn key ->
          QueryCache.delete(name, tenant_id, key)
          DiskCache.delete(name, tenant_id, key)
          HotCache.delete(tenant_id, key)
        end)

        :ok
    end
  end

  @doc """
  Invalidates every list-scoped cache key recorded for `table`.

  Used on row insert: a new row's primary key was never indexed, so it
  can't be purged via `invalidate_by_row/3`. Single-row cache entries are
  left untouched since an insert cannot affect them.
  """
  @spec invalidate_lists(tenant_id(), String.t(), atom()) :: :ok
  def invalidate_lists(tenant_id, table, name \\ __MODULE__) do
    TenantId.cast!(tenant_id)

    case TenantRegistry.whereis(name, tenant_id, :reverse_index) do
      nil ->
        :ok

      _ ->
        cache_keys = ReverseIndex.purge_list_keys(name, tenant_id, table)

        Enum.each(cache_keys, fn key ->
          QueryCache.delete(name, tenant_id, key)
          DiskCache.delete(name, tenant_id, key)
        end)

        :ok
    end
  end

  @doc """
  Invalidates every cache key that depends on the row `{table, pk}`.
  """
  @spec invalidate_by_row(tenant_id(), String.t(), primary_key(), atom()) :: :ok
  def invalidate_by_row(tenant_id, table, pk, name \\ __MODULE__) do
    TenantId.cast!(tenant_id)
    TenantSupervisor.ensure_started(name, tenant_id)
    cache_keys = ReverseIndex.purge_row(name, tenant_id, table, pk)

    Enum.each(cache_keys, fn key ->
      QueryCache.delete(name, tenant_id, key)
      DiskCache.delete(name, tenant_id, key)
      HotCache.delete(tenant_id, key)
    end)

    :ok
  end

  @doc """
  Returns the number of keys held in the tenant's disk cache.
  """
  @spec size(tenant_id(), atom()) :: non_neg_integer()
  def size(tenant_id, name \\ __MODULE__) do
    TenantId.cast!(tenant_id)
    TenantSupervisor.ensure_started(name, tenant_id)
    DiskCache.count(name, tenant_id)
  end

  @doc """
  Returns the number of persisted entries held for the tenant.
  """
  @spec persist_count(tenant_id(), atom()) :: non_neg_integer()
  def persist_count(tenant_id, name \\ __MODULE__) do
    case TenantRegistry.get_value(name, tenant_id, :qc_persist) do
      nil -> 0
      ref -> :counters.get(ref, 1)
    end
  end

  @doc """
  Marks `key` as persisted or not, honouring the per-tenant persist cap.

  Pass `replicated: true` in `opts` to apply a peer's change without
  re-broadcasting it.
  """
  @spec set_persist(tenant_id(), Key.t(), boolean(), keyword(), atom()) ::
          :ok | {:error, :persist_cap | :not_found}
  def set_persist(tenant_id, key, persist, opts \\ [], name \\ __MODULE__) do
    TenantId.cast!(tenant_id)
    TenantSupervisor.ensure_started(name, tenant_id)

    case DiskCache.peek_meta(name, tenant_id, key) do
      :miss ->
        {:error, :not_found}

      {:ok, %{persist: ^persist}} ->
        :ok

      {:ok, %{persist: false}} ->
        cap = InstanceConfig.get(name, :persist_cap, 50_000)
        ref = TenantRegistry.get_value(name, tenant_id, :qc_persist)
        :counters.add(ref, 1, 1)
        new_count = :counters.get(ref, 1)

        if new_count > cap do
          :counters.sub(ref, 1, 1)

          :telemetry.execute([:restdis, :persist, :cap_reached], %{count: 1}, %{
            tenant_id: tenant_id
          })

          {:error, :persist_cap}
        else
          :ok = DiskCache.set_persist(name, tenant_id, key, true)

          :telemetry.execute([:restdis, :persist, :count], %{count: new_count}, %{
            tenant_id: tenant_id
          })

          broadcast_persisted_value(name, tenant_id, key, opts)

          :ok
        end

      {:ok, %{persist: true}} ->
        :ok = DiskCache.set_persist(name, tenant_id, key, false)
        ref = TenantRegistry.get_value(name, tenant_id, :qc_persist)
        :counters.sub(ref, 1, 1)
        new_count = :counters.get(ref, 1)

        :telemetry.execute([:restdis, :persist, :count], %{count: new_count}, %{
          tenant_id: tenant_id
        })

        maybe_broadcast(opts, name, tenant_id, {:set_persist, key, false})
        :ok

      :not_found ->
        {:error, :not_found}
    end
  end

  @doc """
  Reads `key` from the cache layers without falling back to the origin.
  """
  @spec peek(tenant_id(), Key.t(), atom()) :: {:ok, term()} | :miss
  def peek(tenant_id, key, name \\ __MODULE__) do
    TenantId.cast!(tenant_id)
    TenantSupervisor.ensure_started(name, tenant_id)

    with :miss <- QueryCache.get(name, tenant_id, key) do
      disk_get_and_promote(name, tenant_id, key)
    end
  end

  @doc """
  Returns the milliseconds remaining before `key` expires, `:infinity` for a
  key with no TTL, or `:miss` if it isn't held in this node's query cache.
  """
  @spec ttl(tenant_id(), Key.t(), atom()) :: non_neg_integer() | :infinity | :miss
  def ttl(tenant_id, key, name \\ __MODULE__) do
    QueryCache.ttl_ms(name, tenant_id, key)
  end

  defp disk_get_and_promote(name, tenant_id, key) do
    case DiskCache.get_with_ttl(name, tenant_id, key) do
      {:ok, value, ttl_ms} ->
        QueryCache.put(name, tenant_id, key, value, ttl_ms: ttl_ms)
        {:ok, value}

      :miss ->
        :miss
    end
  end

  defp origin_fetch(name, tenant_id, key) do
    origin = InstanceConfig.fetch!(name).origin

    case origin.fetch(tenant_id, key) do
      {:ok, value} ->
        do_put(name, tenant_id, key, value, [])
        {:ok, value}

      :error ->
        :miss
    end
  end

  defp do_put(name, tenant_id, key, value, opts) do
    persist = Keyword.get(opts, :persist, false)
    persist_cap = Keyword.get(opts, :persist_cap, @default_persist_cap)
    ttl_ms = Keyword.get(opts, :ttl_ms)

    already_persisted? =
      match?({:ok, %{persist: true}}, DiskCache.peek_meta(name, tenant_id, key))

    cond do
      persist and already_persisted? ->
        QueryCache.put(name, tenant_id, key, value, opts)
        DiskCache.put(name, tenant_id, key, value, persist: true, ttl_ms: ttl_ms)
        index_value(name, tenant_id, key, value, opts)
        maybe_broadcast(opts, name, tenant_id, {:put, key, value, opts})
        :ok

      persist ->
        ref = TenantRegistry.get_value(name, tenant_id, :qc_persist)
        :counters.add(ref, 1, 1)
        new_count = :counters.get(ref, 1)

        if new_count > persist_cap do
          :counters.sub(ref, 1, 1)

          :telemetry.execute([:restdis, :persist, :cap_reached], %{count: 1}, %{
            tenant_id: tenant_id
          })

          {:error, :persist_cap}
        else
          QueryCache.put(name, tenant_id, key, value, opts)
          DiskCache.put(name, tenant_id, key, value, persist: true, ttl_ms: ttl_ms)
          index_value(name, tenant_id, key, value, opts)

          :telemetry.execute([:restdis, :persist, :count], %{count: new_count}, %{
            tenant_id: tenant_id
          })

          maybe_broadcast(opts, name, tenant_id, {:put, key, value, opts})

          :ok
        end

      already_persisted? ->
        decrement_persist(name, tenant_id)
        QueryCache.put(name, tenant_id, key, value, opts)
        DiskCache.put(name, tenant_id, key, value, ttl_ms: ttl_ms)
        index_value(name, tenant_id, key, value, opts)
        maybe_broadcast(opts, name, tenant_id, {:put, key, value, opts})
        :ok

      true ->
        QueryCache.put(name, tenant_id, key, value, opts)
        DiskCache.put(name, tenant_id, key, value, ttl_ms: ttl_ms)
        index_value(name, tenant_id, key, value, opts)
        :ok
    end
  end

  defp index_value(name, tenant_id, key, value, opts) do
    pk_column = opts[:pk_column] || "id"
    table = key.ident

    pks =
      case opts[:primary_keys] do
        nil -> extract_pks(value, pk_column)
        explicit -> explicit
      end

    Enum.each(pks, fn pk ->
      ReverseIndex.add(name, tenant_id, table, pk, key)
    end)

    if is_list(value), do: ReverseIndex.add_list_key(tenant_id, table, key)
  end

  defp extract_pks(value, pk_column) when is_map(value) do
    case Map.fetch(value, pk_column) do
      {:ok, pk} -> [pk]
      :error -> []
    end
  end

  defp extract_pks(values, pk_column) when is_list(values) do
    Enum.flat_map(values, fn
      item when is_map(item) ->
        case Map.fetch(item, pk_column) do
          {:ok, pk} -> [pk]
          :error -> []
        end

      _ ->
        []
    end)
  end

  defp extract_pks(_, _), do: []

  defp maybe_broadcast(opts, name, tenant_id, event) do
    if opts[:replicated], do: :ok, else: Replication.broadcast(name, tenant_id, event)
  end

  defp broadcast_persisted_value(name, tenant_id, key, opts) do
    if opts[:replicated], do: :ok, else: broadcast_persisted_value(name, tenant_id, key)
  end

  defp broadcast_persisted_value(name, tenant_id, key) do
    case DiskCache.get(name, tenant_id, key) do
      {:ok, value} ->
        Replication.broadcast(name, tenant_id, {:put, key, value, persist: true})

      :miss ->
        :ok
    end
  end

  defp decrement_persist(name, tenant_id) do
    case TenantRegistry.get_value(name, tenant_id, :qc_persist) do
      nil ->
        :ok

      ref ->
        :counters.sub(ref, 1, 1)
        new_count = :counters.get(ref, 1)

        :telemetry.execute([:restdis, :persist, :count], %{count: new_count}, %{
          tenant_id: tenant_id
        })

        :ok
    end
  end
end
