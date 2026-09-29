defmodule RestdisServer.TenantStore do
  @moduledoc """
  Behaviour for resolving tenants and API keys.

  `fetch_by_api_key/1` also returns `:pgrst_credential`, the effective upstream
  PostgREST credential of that key: its own `pgrst_api_key` when set, else the
  tenant's `pgrst_api_key`.
  """

  @type api_key :: String.t()
  @type tenant_id :: String.t()

  @type tenant_config :: %{
          tenant_id: tenant_id(),
          default_ttl_s: pos_integer(),
          max_ttl_s: pos_integer(),
          persist_cap: pos_integer(),
          pgrst_base_url: String.t(),
          pgrst_api_key: String.t(),
          replica_url: String.t() | nil,
          allow_shape_deletion: boolean(),
          direct_pg_url: String.t() | nil,
          max_shapes: pos_integer() | nil,
          max_log_bytes: pos_integer() | nil,
          max_waiting_clients: pos_integer() | nil
        }

  @type api_key_config :: %{
          required(:pgrst_credential) => String.t(),
          optional(atom()) => term()
        }

  @callback fetch_by_api_key(api_key()) :: {:ok, api_key_config()} | {:error, :not_found}
  @callback fetch_by_tenant(tenant_id()) :: {:ok, tenant_config()} | {:error, :not_found}
  @callback list_all() :: [tenant_config()]
end
