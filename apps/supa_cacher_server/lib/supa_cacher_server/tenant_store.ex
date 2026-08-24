defmodule SupaCacherServer.TenantStore do
  @moduledoc """
  Behaviour for resolving tenants and API keys.
  """

  @type api_key :: String.t()
  @type tenant_id :: String.t()

  @type tenant_config :: %{
          tenant_id: tenant_id(),
          default_ttl_s: pos_integer(),
          persist_cap: pos_integer(),
          pgrst_base_url: String.t(),
          pgrst_api_key: String.t(),
          replica_url: String.t() | nil
        }

  @callback fetch_by_api_key(api_key()) :: {:ok, tenant_config()} | {:error, :not_found}
  @callback fetch_by_tenant(tenant_id()) :: {:ok, tenant_config()} | {:error, :not_found}
  @callback list_all() :: [tenant_config()]
end
