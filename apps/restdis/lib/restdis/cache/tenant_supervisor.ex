defmodule Restdis.Cache.TenantSupervisor do
  @moduledoc """
  Dynamic supervisor starting one tenant aggregate per tenant.
  """

  use DynamicSupervisor

  alias Restdis.Cache.Tenant

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

  Always asks the `DynamicSupervisor` to start the child rather than checking
  `TenantRegistry` first: a `:via`-named process registers before its `init/1`
  runs, so a registry lookup can observe the tenant supervisor while its
  children (in particular `QueryCache`, which callers rely on immediately
  after this returns) are still starting. `DynamicSupervisor.start_child/2`
  itself only replies once the child's `start_link/1` — and therefore every
  grandchild's `init/1` — has returned, so racing callers cannot observe a
  half-started tenant.
  """
  @spec ensure_started(String.t()) :: :ok
  def ensure_started(tenant_id) do
    data_dir = Application.fetch_env!(:restdis, :cache_data_dir)
    child_spec = {Tenant, tenant_id: tenant_id, data_dir: data_dir}

    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
