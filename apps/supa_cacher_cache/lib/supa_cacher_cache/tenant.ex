defmodule SupaCacherCache.Tenant do
  use Supervisor

  alias SupaCacherCache.DiskCache
  alias SupaCacherCache.QueryCache
  alias SupaCacherCache.ReverseIndex
  alias SupaCacherCache.TenantRegistry

  def child_spec(opts) do
    tenant_id = Keyword.fetch!(opts, :tenant_id)

    %{
      id: {__MODULE__, tenant_id},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :temporary
    }
  end

  def start_link(opts) do
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    Supervisor.start_link(__MODULE__, opts, name: TenantRegistry.via(tenant_id, :tenant))
  end

  @impl Supervisor
  def init(opts) do
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    data_dir = Keyword.fetch!(opts, :data_dir)

    children = [
      QueryCache.child_spec(tenant_id),
      {DiskCache, tenant_id: tenant_id, data_dir: data_dir},
      {ReverseIndex, tenant_id: tenant_id}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
