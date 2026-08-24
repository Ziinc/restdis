defmodule SupaCacherServer.TenantStore.Repo do
  @moduledoc """
  Tenant store backed by the control-plane database.
  """

  @behaviour SupaCacherServer.TenantStore

  import Ecto.Query

  alias SupaCacherRepo.ApiKeys
  alias SupaCacherRepo.Tenants

  @impl SupaCacherServer.TenantStore
  def fetch_by_api_key(api_key) do
    query =
      from(a in ApiKeys,
        join: t in Tenants,
        on: t.tenant_id == a.tenant_id,
        where: a.api_key == ^api_key and a.status == "active",
        select: t
      )

    case SupaCacherRepo.one(query) do
      nil -> {:error, :not_found}
      tenant -> {:ok, to_config(tenant)}
    end
  end

  @impl SupaCacherServer.TenantStore
  def fetch_by_tenant(tenant_id) do
    case SupaCacherRepo.get(Tenants, tenant_id) do
      nil -> {:error, :not_found}
      tenant -> {:ok, to_config(tenant)}
    end
  end

  @impl SupaCacherServer.TenantStore
  def list_all do
    SupaCacherRepo.all(Tenants) |> Enum.map(&to_config/1)
  end

  defp to_config(tenant) do
    %{
      tenant_id: tenant.tenant_id,
      default_ttl_s: tenant.default_ttl_s,
      persist_cap: tenant.persist_cap,
      pgrst_base_url: tenant.pgrst_base_url,
      pgrst_api_key: tenant.pgrst_api_key,
      replica_url: tenant.replica_url
    }
  end
end
