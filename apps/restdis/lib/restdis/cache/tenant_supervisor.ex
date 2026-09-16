defmodule Restdis.Cache.TenantSupervisor do
  @moduledoc """
  Dynamic supervisor starting one tenant aggregate per tenant.
  """

  use DynamicSupervisor

  alias Restdis.Cache.Tenant
  alias Restdis.Cache.TenantRegistry

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

  Checks `TenantRegistry` for `:reverse_index` first — the last child
  `Tenant.init/1` starts, so finding it registered proves the whole tenant
  aggregate (including `QueryCache`, which callers rely on immediately after
  this returns) has finished starting. This turns the common case, where the
  tenant is already running, into a lock-free `Registry` lookup instead of a
  `GenServer.call` to the single `DynamicSupervisor` shared by every tenant.

  Falls through to `DynamicSupervisor.start_child/2` on a miss, which is safe
  under races: it only replies once the child's `start_link/1` — and
  therefore every grandchild's `init/1` — has returned, so racing callers
  cannot observe a half-started tenant.
  """
  @spec ensure_started(String.t()) :: :ok
  def ensure_started(tenant_id) do
    case TenantRegistry.whereis(tenant_id, :reverse_index) do
      nil -> start_tenant(tenant_id)
      _pid -> :ok
    end
  end

  defp start_tenant(tenant_id) do
    data_dir = Application.fetch_env!(:restdis, :cache_data_dir)
    child_spec = {Tenant, tenant_id: tenant_id, data_dir: data_dir}

    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
