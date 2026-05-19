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

  @spec put(String.t(), Key.t(), term()) :: :ok
  def put(tenant_id, key, value) do
    GenServer.call(TenantRegistry.via(tenant_id, :disk_cache), {:put, key, value})
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
    {:ok, %{cubdb: cubdb}}
  end

  @impl GenServer
  def handle_call({:get, key}, _from, %{cubdb: cubdb} = state) do
    result =
      case CubDB.fetch(cubdb, key) do
        {:ok, value} -> {:ok, value}
        :error -> :miss
      end

    {:reply, result, state}
  end

  def handle_call({:put, key, value}, _from, %{cubdb: cubdb} = state) do
    :ok = CubDB.put(cubdb, key, value)
    {:reply, :ok, state}
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
end
