defmodule SupaCacherCache.TenantSupervisor do
  @moduledoc """
  Dynamic supervisor starting one tenant aggregate per tenant.
  """

  use DynamicSupervisor

  alias SupaCacherCache.Tenant
  alias SupaCacherCache.TenantRegistry

  @doc """
  Starts the supervisor of the tenant aggregates.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl DynamicSupervisor
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts the tenant aggregate for `tenant_id` unless it is already running.
  """
  @spec ensure_started(String.t()) :: :ok
  def ensure_started(tenant_id) do
    case TenantRegistry.whereis(tenant_id, :tenant) do
      nil -> start_tenant(tenant_id)
      _pid -> :ok
    end
  end

  defp start_tenant(tenant_id) do
    data_dir = Application.fetch_env!(:supa_cacher_cache, :cache_data_dir)
    child_spec = {Tenant, tenant_id: tenant_id, data_dir: data_dir}

    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
