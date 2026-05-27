defmodule SupaCacherCache.DiskCache do
  use GenServer

  alias SupaCacherCache.Key
  alias SupaCacherCache.TenantRegistry

  def start_link(opts) do
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    GenServer.start_link(__MODULE__, opts, name: TenantRegistry.via(tenant_id, :disk_cache))
  end

  @spec get(String.t(), Key.t()) :: {:ok, term()} | :miss
  def get(tenant_id, key) do
    GenServer.call(TenantRegistry.via(tenant_id, :disk_cache), {:get, key})
  end

  @spec put(String.t(), Key.t(), term(), keyword()) :: :ok
  def put(tenant_id, key, value, opts \\ []) do
    persist = Keyword.get(opts, :persist, false)
    GenServer.call(TenantRegistry.via(tenant_id, :disk_cache), {:put, key, value, persist})
  end

  @spec set_persist(String.t(), Key.t(), boolean()) :: :ok | :not_found
  def set_persist(tenant_id, key, persist) do
    GenServer.call(TenantRegistry.via(tenant_id, :disk_cache), {:set_persist, key, persist})
  end

  @spec peek_meta(String.t(), Key.t()) :: {:ok, %{persist: boolean()}} | :miss
  def peek_meta(tenant_id, key) do
    GenServer.call(TenantRegistry.via(tenant_id, :disk_cache), {:peek_meta, key})
  end

  @spec delete(String.t(), Key.t()) :: :ok
  def delete(tenant_id, key) do
    GenServer.cast(TenantRegistry.via(tenant_id, :disk_cache), {:delete, key})
  end

  @spec flush(String.t()) :: :ok
  def flush(tenant_id) do
    GenServer.call(TenantRegistry.via(tenant_id, :disk_cache), :flush)
  end

  @impl GenServer
  def init(opts) do
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    data_dir = Keyword.fetch!(opts, :data_dir)
    tenant_dir = Path.join(data_dir, tenant_id)
    File.mkdir_p!(tenant_dir)
    {:ok, cubdb} = CubDB.start_link(data_dir: tenant_dir)
    recount_persist(tenant_id, cubdb)
    {:ok, %{cubdb: cubdb}}
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
    :ok = CubDB.put(cubdb, key, {:v1, %{value: value, persist: persist}})
    {:reply, :ok, state}
  end

  def handle_call({:set_persist, key, persist}, _from, %{cubdb: cubdb} = state) do
    result =
      case CubDB.fetch(cubdb, key) do
        {:ok, {:v1, %{value: value}}} ->
          :ok = CubDB.put(cubdb, key, {:v1, %{value: value, persist: persist}})
          :ok

        {:ok, value} ->
          :ok = CubDB.put(cubdb, key, {:v1, %{value: value, persist: persist}})
          :ok

        :error ->
          :not_found
      end

    {:reply, result, state}
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

  def handle_call(:flush, _from, %{cubdb: cubdb} = state) do
    CubDB.clear(cubdb)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_cast({:delete, key}, %{cubdb: cubdb} = state) do
    CubDB.delete(cubdb, key)
    {:noreply, state}
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
