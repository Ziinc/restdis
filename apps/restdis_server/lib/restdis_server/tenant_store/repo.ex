defmodule RestdisServer.TenantStore.Repo do
  @moduledoc """
  Tenant store backed by the control-plane database.
  """

  @behaviour RestdisServer.TenantStore

  import Ecto.Query

  alias RestdisRepo.ApiKeys
  alias RestdisRepo.ShapeDefinitions
  alias RestdisRepo.Tenants

  @impl RestdisServer.TenantStore
  def fetch_by_api_key(api_key) do
    query =
      from(a in ApiKeys,
        join: t in Tenants,
        on: t.tenant_id == a.tenant_id,
        where: a.api_key == ^api_key and a.status == "active",
        select: t
      )

    case RestdisRepo.one(query) do
      nil -> {:error, :not_found}
      tenant -> {:ok, to_config(tenant)}
    end
  end

  @impl RestdisServer.TenantStore
  def fetch_by_tenant(tenant_id) do
    case RestdisRepo.get(Tenants, tenant_id) do
      nil -> {:error, :not_found}
      tenant -> {:ok, to_config(tenant)}
    end
  end

  @impl RestdisServer.TenantStore
  def list_all do
    RestdisRepo.all(Tenants) |> Enum.map(&to_config/1)
  end

  defp to_config(tenant) do
    %{
      tenant_id: tenant.tenant_id,
      default_ttl_s: tenant.default_ttl_s,
      persist_cap: tenant.persist_cap,
      pgrst_base_url: tenant.pgrst_base_url,
      pgrst_api_key: tenant.pgrst_api_key,
      replica_url: tenant.replica_url,
      allow_shape_deletion: tenant.allow_shape_deletion,
      direct_pg_url: tenant.direct_pg_url,
      max_shapes: tenant.max_shapes,
      max_log_bytes: tenant.max_log_bytes,
      max_waiting_clients: tenant.max_waiting_clients,
      shape_secret: tenant.shape_secret,
      auth_mode: tenant.auth_mode,
      max_log_operations: tenant.max_log_operations,
      shapes: shapes_by_name(tenant.tenant_id)
    }
  end

  # `restdis_electric` depends on `restdis` only, so named shapes cross the boundary as plain data on `tenant_config`.
  defp shapes_by_name(tenant_id) do
    query = from(s in ShapeDefinitions, where: s.tenant_id == ^tenant_id)

    query
    |> RestdisRepo.all()
    |> Map.new(fn shape ->
      {shape.name,
       %{table: shape.table, where: shape.where, columns: shape.columns, replica: shape.replica}}
    end)
  end
end
