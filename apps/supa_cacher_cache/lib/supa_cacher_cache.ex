defmodule SupaCacherCache do
  alias SupaCacherCache.DiskCache
  alias SupaCacherCache.Key
  alias SupaCacherCache.QueryCache
  alias SupaCacherCache.ReverseIndex
  alias SupaCacherCache.TenantId
  alias SupaCacherCache.TenantRegistry
  alias SupaCacherCache.TenantSupervisor

  @type tenant_id :: String.t()
  @type primary_key :: term()

  @spec get(tenant_id(), Key.t()) :: {:ok, term()} | :miss
  def get(tenant_id, key) do
    TenantId.cast!(tenant_id)
    TenantSupervisor.ensure_started(tenant_id)

    with :miss <- QueryCache.get(tenant_id, key),
         :miss <- disk_get_and_promote(tenant_id, key) do
      origin_fetch(tenant_id, key)
    end
  end

  @spec put(tenant_id(), Key.t(), term(), keyword()) :: :ok | {:error, :persist_cap}
  def put(tenant_id, key, value, opts \\ []) do
    TenantId.cast!(tenant_id)
    TenantSupervisor.ensure_started(tenant_id)
    do_put(tenant_id, key, value, opts)
  end

  @spec delete(tenant_id(), Key.t()) :: :ok
  def delete(tenant_id, key) do
    TenantId.cast!(tenant_id)
    TenantSupervisor.ensure_started(tenant_id)

    case DiskCache.peek_meta(tenant_id, key) do
      {:ok, %{persist: true}} -> decrement_persist(tenant_id)
      _ -> :ok
    end

    QueryCache.delete(tenant_id, key)
    DiskCache.delete(tenant_id, key)
    ReverseIndex.purge_key(tenant_id, key)
    :ok
  end

  @spec flush_tenant(tenant_id()) :: :ok
  def flush_tenant(tenant_id) do
    TenantId.cast!(tenant_id)
    case TenantRegistry.whereis(tenant_id, :tenant) do
      nil -> :ok
      pid -> Supervisor.stop(pid, :normal)
    end

    :persistent_term.erase({:sc_persist, tenant_id})

    data_dir = Application.fetch_env!(:supa_cacher_cache, :cache_data_dir)
    tenant_dir = Path.join(data_dir, tenant_id)
    if File.exists?(tenant_dir), do: File.rm_rf!(tenant_dir)
    :ok
  end

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

  @spec persist_count(tenant_id()) :: non_neg_integer()
  def persist_count(tenant_id) do
    case :persistent_term.get({:sc_persist, tenant_id}, nil) do
      nil -> 0
      ref -> :counters.get(ref, 1)
    end
  end

  @spec set_persist(tenant_id(), Key.t(), boolean()) :: :ok | {:error, :persist_cap | :not_found}
  def set_persist(tenant_id, key, persist) do
    TenantId.cast!(tenant_id)
    TenantSupervisor.ensure_started(tenant_id)

    case DiskCache.peek_meta(tenant_id, key) do
      :miss ->
        {:error, :not_found}

      {:ok, %{persist: ^persist}} ->
        :ok

      {:ok, %{persist: false}} ->
        cap = 50_000
        ref = :persistent_term.get({:sc_persist, tenant_id})
        :counters.add(ref, 1, 1)
        new_count = :counters.get(ref, 1)

        if new_count > cap do
          :counters.sub(ref, 1, 1)
          :telemetry.execute([:supa_cacher_cache, :persist, :cap_reached], %{count: 1}, %{tenant_id: tenant_id})
          {:error, :persist_cap}
        else
          :ok = DiskCache.set_persist(tenant_id, key, true)
          :telemetry.execute([:supa_cacher_cache, :persist, :count], %{count: new_count}, %{tenant_id: tenant_id})
          :ok
        end

      {:ok, %{persist: true}} ->
        :ok = DiskCache.set_persist(tenant_id, key, false)
        ref = :persistent_term.get({:sc_persist, tenant_id})
        :counters.sub(ref, 1, 1)
        new_count = :counters.get(ref, 1)
        :telemetry.execute([:supa_cacher_cache, :persist, :count], %{count: new_count}, %{tenant_id: tenant_id})
        :ok
    end
  end

  @spec peek(tenant_id(), Key.t()) :: {:ok, term()} | :miss
  def peek(tenant_id, key) do
    TenantId.cast!(tenant_id)
    TenantSupervisor.ensure_started(tenant_id)

    with :miss <- QueryCache.get(tenant_id, key) do
      disk_get_and_promote(tenant_id, key)
    end
  end

  defp disk_get_and_promote(tenant_id, key) do
    case DiskCache.get(tenant_id, key) do
      {:ok, value} ->
        QueryCache.put(tenant_id, key, value)
        {:ok, value}

      :miss ->
        :miss
    end
  end

  defp origin_fetch(tenant_id, key) do
    origin = Application.fetch_env!(:supa_cacher_cache, :origin)

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
    persist_cap = Keyword.get(opts, :persist_cap, 50_000)

    if persist do
      ref = :persistent_term.get({:sc_persist, tenant_id})
      :counters.add(ref, 1, 1)
      new_count = :counters.get(ref, 1)

      if new_count > persist_cap do
        :counters.sub(ref, 1, 1)
        :telemetry.execute([:supa_cacher_cache, :persist, :cap_reached], %{count: 1}, %{tenant_id: tenant_id})
        {:error, :persist_cap}
      else
        QueryCache.put(tenant_id, key, value, opts)
        DiskCache.put(tenant_id, key, value, persist: true)
        index_value(tenant_id, key, value, opts)
        :telemetry.execute([:supa_cacher_cache, :persist, :count], %{count: new_count}, %{tenant_id: tenant_id})
        :ok
      end
    else
      QueryCache.put(tenant_id, key, value, opts)
      DiskCache.put(tenant_id, key, value)
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

  defp decrement_persist(tenant_id) do
    case :persistent_term.get({:sc_persist, tenant_id}, nil) do
      nil ->
        :ok

      ref ->
        :counters.sub(ref, 1, 1)
        new_count = :counters.get(ref, 1)
        :telemetry.execute([:supa_cacher_cache, :persist, :count], %{count: new_count}, %{tenant_id: tenant_id})
        :ok
    end
  end
end
