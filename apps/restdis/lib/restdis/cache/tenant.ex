defmodule Restdis.Cache.Tenant do
  @moduledoc """
  Tenant aggregate owning the query cache, disk cache, reverse index and config snapshot.
  """

  use Supervisor

  alias Restdis.Cache.DiskCache
  alias Restdis.Cache.QueryCache
  alias Restdis.Cache.ReverseIndex
  alias Restdis.Cache.TenantRegistry

  @doc """
  Returns the child spec of the tenant aggregate for the tenant given in `opts`.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    tenant_id = Keyword.fetch!(opts, :tenant_id)

    %{
      id: {__MODULE__, tenant_id},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :temporary
    }
  end

  @doc """
  Starts the tenant aggregate and its cache processes.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    Supervisor.start_link(__MODULE__, opts, name: TenantRegistry.via(name, tenant_id, :tenant))
  end

  @impl Supervisor
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    data_dir = Keyword.fetch!(opts, :data_dir)

    children = [
      QueryCache.child_spec(name, tenant_id),
      {DiskCache, name: name, tenant_id: tenant_id, data_dir: data_dir},
      {ReverseIndex, name: name, tenant_id: tenant_id}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
