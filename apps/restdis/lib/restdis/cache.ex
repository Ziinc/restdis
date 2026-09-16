defmodule Restdis.Cache do
  @moduledoc """
  Public API of the cache bounded context: get, put, delete, peek and table flushes.
  """

  alias Restdis.Cache.DiskCache
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
  supervisor, e.g. `{Restdis.Cache, []}`.

  `:restdis` declares no `mod:` application callback, so depending on it
  starts no processes; a host must mount this explicitly.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {Restdis.Cache.Supervisor, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc """
  Reads `key`, falling back from the query cache to the disk cache to the origin.
  """
  @spec get(tenant_id(), Key.t()) :: {:ok, term()} | :miss
  def get(tenant_id, key) do
    TenantId.cast!(tenant_id)
    TenantSupervisor.ensure_started(tenant_id)

    with :miss <- QueryCache.get(tenant_id, key),
         :miss <- disk_get_and_promote(tenant_id, key) do
      origin_fetch(tenant_id, key)
    end
  end

  @doc """
  Writes `value` under `key`. Pass `:ttl_ms` and `:persist` in `opts`.
  """
  @spec put(tenant_id(), Key.t(), term(), keyword()) :: :ok | {:error, :persist_cap}
  def put(tenant_id, key, value, opts \\ []) do
    TenantId.cast!(tenant_id)
    TenantSupervisor.ensure_started(tenant_id)
    do_put(tenant_id, key, value, opts)
  end

  @doc """
  Removes `key` from every cache layer and from the reverse index.

  Pass `replicated: true` in `opts` to apply a peer's delete without
  re-broadcasting it.
  """
  @spec delete(tenant_id(), Key.t(), keyword()) :: :ok
  def delete(tenant_id, key, opts \\ []) do
    TenantId.cast!(tenant_id)
    TenantSupervisor.ensure_started(tenant_id)

    case DiskCache.peek_meta(tenant_id, key) do
      {:ok, %{persist: true}} ->
        decrement_persist(tenant_id)
        maybe_broadcast(opts, tenant_id, {:delete, key})

      _ ->
        :ok
    end

    QueryCache.delete(tenant_id, key)
    DiskCache.delete(tenant_id, key)
    ReverseIndex.purge_key(tenant_id, key)
    :ok
  end

  @doc """
  Stops the tenant aggregate and deletes its on-disk data.
  """
  @spec flush_tenant(tenant_id()) :: :ok
  def flush_tenant(tenant_id) do
    TenantId.cast!(tenant_id)

    case TenantRegistry.whereis(tenant_id, :tenant) do
      nil -> :ok
      pid -> Supervisor.stop(pid, :normal)
    end

    :persistent_term.erase({:sc_persist, tenant_id})

    data_dir = Application.fetch_env!(:restdis, :cache_data_dir)
    tenant_dir = Path.join(data_dir, tenant_id)
    if File.exists?(tenant_dir), do: File.rm_rf!(tenant_dir)
    :ok
  end

  @doc """
  Invalidates every cache key that depends on `table`.
  """
  @spec flush_table(tenant_id(), String.t()) :: :ok
  def flush_table(tenant_id, table) do
    TenantId.cast!(tenant_id)

    case TenantRegistry.whereis(tenant_id, :reverse_index) do
      nil ->
        :ok

      _ ->
        cache_keys = ReverseIndex.purge_table(tenant_id, table)

        Enum.each(cache_keys, fn key ->
          QueryCache.delete(tenant_id, key)
          DiskCache.delete(tenant_id, key)
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
  @spec invalidate_lists(tenant_id(), String.t()) :: :ok
  def invalidate_lists(tenant_id, table) do
    TenantId.cast!(tenant_id)

    case TenantRegistry.whereis(tenant_id, :reverse_index) do
      nil ->
        :ok

      _ ->
        cache_keys = ReverseIndex.purge_list_keys(tenant_id, table)

        Enum.each(cache_keys, fn key ->
          QueryCache.delete(tenant_id, key)
          DiskCache.delete(tenant_id, key)
        end)

        :ok
    end
  end

  @doc """
  Invalidates every cache key that depends on the row `{table, pk}`.
  """
  @spec invalidate_by_row(tenant_id(), String.t(), primary_key()) :: :ok
  def invalidate_by_row(tenant_id, table, pk) do
    TenantId.cast!(tenant_id)
    TenantSupervisor.ensure_started(tenant_id)
    cache_keys = ReverseIndex.purge_row(tenant_id, table, pk)

    Enum.each(cache_keys, fn key ->
      QueryCache.delete(tenant_id, key)
      DiskCache.delete(tenant_id, key)
    end)

    :ok
  end

  @doc """
  Returns the number of keys held in the tenant's disk cache.
  """
  @spec size(tenant_id()) :: non_neg_integer()
  def size(tenant_id) do
    TenantId.cast!(tenant_id)
    TenantSupervisor.ensure_started(tenant_id)
    DiskCache.count(tenant_id)
  end

  @doc """
  Returns the number of persisted entries held for the tenant.
  """
  @spec persist_count(tenant_id()) :: non_neg_integer()
  def persist_count(tenant_id) do
    case :persistent_term.get({:sc_persist, tenant_id}, nil) do
      nil -> 0
      ref -> :counters.get(ref, 1)
    end
  end

  @doc """
  Marks `key` as persisted or not, honouring the per-tenant persist cap.

  Pass `replicated: true` in `opts` to apply a peer's change without
  re-broadcasting it.
  """
  @spec set_persist(tenant_id(), Key.t(), boolean(), keyword()) ::
          :ok | {:error, :persist_cap | :not_found}
  def set_persist(tenant_id, key, persist, opts \\ []) do
    persist_cap = Keyword.get(opts, :persist_cap, @default_persist_cap)
    TenantId.cast!(tenant_id)
    TenantSupervisor.ensure_started(tenant_id)

    case DiskCache.peek_meta(tenant_id, key) do
      :miss ->
        {:error, :not_found}

      {:ok, %{persist: ^persist}} ->
        :ok

      {:ok, %{persist: false}} ->
        ref = :persistent_term.get({:sc_persist, tenant_id})
        :counters.add(ref, 1, 1)
        new_count = :counters.get(ref, 1)

        if new_count > persist_cap do
          :counters.sub(ref, 1, 1)

          :telemetry.execute([:restdis, :persist, :cap_reached], %{count: 1}, %{
            tenant_id: tenant_id
          })

          {:error, :persist_cap}
        else
          case DiskCache.set_persist(tenant_id, key, true) do
            :ok ->
              :telemetry.execute([:restdis, :persist, :count], %{count: new_count}, %{
                tenant_id: tenant_id
              })

              broadcast_persisted_value(tenant_id, key, opts)

              :ok

            :not_found ->
              :counters.sub(ref, 1, 1)
              {:error, :not_found}
          end
        end

      {:ok, %{persist: true}} ->
        case DiskCache.set_persist(tenant_id, key, false) do
          :ok ->
            ref = :persistent_term.get({:sc_persist, tenant_id})
            :counters.sub(ref, 1, 1)
            new_count = :counters.get(ref, 1)

            :telemetry.execute([:restdis, :persist, :count], %{count: new_count}, %{
              tenant_id: tenant_id
            })

            maybe_broadcast(opts, tenant_id, {:set_persist, key, false})

            :ok

          :not_found ->
            {:error, :not_found}
        end
    end
  end

  @doc """
  Reads `key` from the cache layers without falling back to the origin.
  """
  @spec peek(tenant_id(), Key.t()) :: {:ok, term()} | :miss
  def peek(tenant_id, key) do
    TenantId.cast!(tenant_id)
    TenantSupervisor.ensure_started(tenant_id)

    with :miss <- QueryCache.get(tenant_id, key) do
      disk_get_and_promote(tenant_id, key)
    end
  end

  defp disk_get_and_promote(tenant_id, key) do
    case DiskCache.get_with_ttl(tenant_id, key) do
      {:ok, value, ttl_ms} ->
        QueryCache.put(tenant_id, key, value, ttl_ms: ttl_ms)
        {:ok, value}

      :miss ->
        :miss
    end
  end

  defp origin_fetch(tenant_id, key) do
    origin = Application.fetch_env!(:restdis, :origin)

    case origin.fetch(tenant_id, key) do
      {:ok, value} ->
        do_put(tenant_id, key, value, [])
        {:ok, value}

      :error ->
        :miss
    end
  end

  defp do_put(tenant_id, key, value, opts) do
    persist = Keyword.get(opts, :persist, false)
    persist_cap = Keyword.get(opts, :persist_cap, @default_persist_cap)
    ttl_ms = Keyword.get(opts, :ttl_ms)
    already_persisted? = match?({:ok, %{persist: true}}, DiskCache.peek_meta(tenant_id, key))

    cond do
      persist and already_persisted? ->
        QueryCache.put(tenant_id, key, value, opts)
        DiskCache.put(tenant_id, key, value, persist: true, ttl_ms: ttl_ms)
        index_value(tenant_id, key, value, opts)
        maybe_broadcast(opts, tenant_id, {:put, key, value, opts})
        :ok

      persist ->
        ref = :persistent_term.get({:sc_persist, tenant_id})
        :counters.add(ref, 1, 1)
        new_count = :counters.get(ref, 1)

        if new_count > persist_cap do
          :counters.sub(ref, 1, 1)

          :telemetry.execute([:restdis, :persist, :cap_reached], %{count: 1}, %{
            tenant_id: tenant_id
          })

          {:error, :persist_cap}
        else
          QueryCache.put(tenant_id, key, value, opts)
          DiskCache.put(tenant_id, key, value, persist: true, ttl_ms: ttl_ms)
          index_value(tenant_id, key, value, opts)

          :telemetry.execute([:restdis, :persist, :count], %{count: new_count}, %{
            tenant_id: tenant_id
          })

          maybe_broadcast(opts, tenant_id, {:put, key, value, opts})

          :ok
        end

      already_persisted? ->
        decrement_persist(tenant_id)
        QueryCache.put(tenant_id, key, value, opts)
        DiskCache.put(tenant_id, key, value, ttl_ms: ttl_ms)
        index_value(tenant_id, key, value, opts)
        maybe_broadcast(opts, tenant_id, {:put, key, value, opts})
        :ok

      true ->
        QueryCache.put(tenant_id, key, value, opts)
        DiskCache.put(tenant_id, key, value, ttl_ms: ttl_ms)
        index_value(tenant_id, key, value, opts)
        :ok
    end
  end

  defp index_value(tenant_id, key, value, opts) do
    pk_column = opts[:pk_column] || "id"
    table = key.ident

    pks =
      case opts[:primary_keys] do
        nil -> extract_pks(value, pk_column)
        explicit -> explicit
      end

    Enum.each(pks, fn pk ->
      ReverseIndex.add(tenant_id, table, pk, key)
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

  defp maybe_broadcast(opts, tenant_id, event) do
    if opts[:replicated], do: :ok, else: Replication.broadcast(tenant_id, event)
  end

  defp broadcast_persisted_value(tenant_id, key, opts) do
    if opts[:replicated], do: :ok, else: broadcast_persisted_value(tenant_id, key)
  end

  defp broadcast_persisted_value(tenant_id, key) do
    case DiskCache.get(tenant_id, key) do
      {:ok, value} -> Replication.broadcast(tenant_id, {:put, key, value, persist: true})
      :miss -> :ok
    end
  end

  defp decrement_persist(tenant_id) do
    case :persistent_term.get({:sc_persist, tenant_id}, nil) do
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
