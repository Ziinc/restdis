defmodule SupaCacherServer.TenantConfig.Cache do
  use GenServer

  @refresh_interval_ms 60_000
  @table :supa_cacher_tenant_config

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec lookup_by_api_key(String.t()) :: {:ok, map()} | {:error, :not_found}
  def lookup_by_api_key(api_key) do
    case :ets.lookup(@table, {:api_key, api_key}) do
      [{_, config}] -> {:ok, config}
      [] -> fetch_and_cache_by_api_key(api_key)
    end
  end

  @spec lookup_by_tenant_id(String.t()) :: {:ok, map()} | {:error, :not_found}
  def lookup_by_tenant_id(tenant_id) do
    case :ets.lookup(@table, {:tenant_id, tenant_id}) do
      [{_, config}] -> {:ok, config}
      [] -> fetch_and_cache_by_tenant(tenant_id)
    end
  end

  @spec invalidate(String.t()) :: :ok
  def invalidate(tenant_id) do
    GenServer.call(__MODULE__, {:invalidate, tenant_id})
  end

  @spec refresh() :: :ok
  def refresh do
    GenServer.call(__MODULE__, :refresh)
  end

  @impl GenServer
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    schedule_refresh()
    {:ok, %{table: table}}
  end

  @impl GenServer
  def handle_call({:invalidate, tenant_id}, _from, state) do
    :ets.match_delete(@table, {{:tenant_id, tenant_id}, :_})

    keys =
      :ets.match(@table, {{:api_key_to_tenant, :"$1"}, tenant_id}) |> List.flatten()

    Enum.each(keys, fn key ->
      :ets.delete(@table, {:api_key, key})
      :ets.delete(@table, {:api_key_to_tenant, key})
    end)

    {:reply, :ok, state}
  end

  def handle_call(:refresh, _from, state) do
    do_refresh()
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info(:refresh, state) do
    do_refresh()
    schedule_refresh()
    {:noreply, state}
  end

  defp fetch_and_cache_by_api_key(api_key) do
    store = store_mod()

    case store.fetch_by_api_key(api_key) do
      {:ok, config} ->
        :ets.insert(@table, {{:api_key, api_key}, config})
        :ets.insert(@table, {{:tenant_id, config.tenant_id}, config})
        {:ok, config}

      error ->
        error
    end
  end

  defp fetch_and_cache_by_tenant(tenant_id) do
    store = store_mod()

    case store.fetch_by_tenant(tenant_id) do
      {:ok, config} ->
        :ets.insert(@table, {{:tenant_id, tenant_id}, config})
        {:ok, config}

      error ->
        error
    end
  end

  defp do_refresh do
    store = store_mod()
    configs = store.list_all()

    Enum.each(configs, fn config ->
      :ets.insert(@table, {{:tenant_id, config.tenant_id}, config})
    end)
  end

  defp store_mod do
    Application.get_env(:supa_cacher_server, :tenant_store, SupaCacherServer.TenantStore.Repo)
  end

  defp schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_interval_ms)
end
