defmodule SupaCacherServer.TenantConfig.Cache do
  @moduledoc """
  Tenant configuration lookups read through the multi-layer cache.

  The cache instance itself (`SupaCacherCache.ReadThrough`) is configured where
  it is supervised; this module owns the periodic refresh and the api-key index
  used to invalidate a tenant's keys.
  """

  use GenServer

  alias SupaCacherCache.ReadThrough

  @cache_name :tenant_config
  @refresh_interval_ms 60_000

  @doc """
  Returns the name of the read-through cache instance holding tenant configs.
  """
  @spec cache_name() :: atom()
  def cache_name, do: @cache_name

  @doc """
  Starts the tenant configuration refresher.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the tenant configuration for `api_key`, reading through on a miss.
  """
  @spec lookup_by_api_key(String.t()) :: {:ok, map()} | {:error, :not_found}
  def lookup_by_api_key(api_key) do
    ReadThrough.fetch(@cache_name, {:api_key, api_key}, fn ->
      case store_mod().fetch_by_api_key(api_key) do
        {:ok, config} ->
          ReadThrough.put(@cache_name, {:tenant_id, config.tenant_id}, config)
          index_api_key(config.tenant_id, api_key)
          {:ok, config}

        error ->
          error
      end
    end)
  end

  @doc """
  Returns the tenant configuration for `tenant_id`, reading through on a miss.
  """
  @spec lookup_by_tenant_id(String.t()) :: {:ok, map()} | {:error, :not_found}
  def lookup_by_tenant_id(tenant_id) do
    ReadThrough.fetch(@cache_name, {:tenant_id, tenant_id}, fn ->
      store_mod().fetch_by_tenant(tenant_id)
    end)
  end

  @doc """
  Drops the cached configuration of `tenant_id` and of its api keys.
  """
  @spec invalidate(String.t()) :: :ok
  def invalidate(tenant_id) do
    GenServer.call(__MODULE__, {:invalidate, tenant_id})
  end

  @doc """
  Reloads every cached tenant configuration.
  """
  @spec refresh() :: :ok
  def refresh do
    GenServer.call(__MODULE__, :refresh)
  end

  @impl GenServer
  def init(_opts) do
    schedule_refresh()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:invalidate, tenant_id}, _from, state) do
    Enum.each(api_keys_of(tenant_id), fn api_key ->
      ReadThrough.delete(@cache_name, {:api_key, api_key})
    end)

    ReadThrough.delete(@cache_name, {:api_keys, tenant_id})
    ReadThrough.delete(@cache_name, {:tenant_id, tenant_id})

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

  defp do_refresh do
    Enum.each(store_mod().list_all(), fn config ->
      ReadThrough.put(@cache_name, {:tenant_id, config.tenant_id}, config)
    end)
  end

  defp index_api_key(tenant_id, api_key) do
    keys = api_keys_of(tenant_id)

    unless api_key in keys do
      ReadThrough.put(@cache_name, {:api_keys, tenant_id}, [api_key | keys])
    end

    :ok
  end

  defp api_keys_of(tenant_id) do
    case ReadThrough.fetch(@cache_name, {:api_keys, tenant_id}, fn -> :miss end) do
      {:ok, keys} -> keys
      _ -> []
    end
  end

  defp store_mod do
    Application.get_env(:supa_cacher_server, :tenant_store, SupaCacherServer.TenantStore.Repo)
  end

  defp schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_interval_ms)
end
