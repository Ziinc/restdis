defmodule RestdisServer.TenantConfig do
  @moduledoc """
  Lookup of tenant configuration used to serve and refetch cache entries.
  """

  alias RestdisServer.TenantConfig.Cache

  @spec lookup_by_api_key(String.t()) :: {:ok, map()} | {:error, :not_found}
  defdelegate lookup_by_api_key(api_key), to: Cache

  @spec lookup_by_tenant_id(String.t()) :: {:ok, map()} | {:error, :not_found}
  defdelegate lookup_by_tenant_id(tenant_id), to: Cache

  @spec invalidate(String.t()) :: :ok
  defdelegate invalidate(tenant_id), to: Cache

  @spec refresh() :: :ok
  defdelegate refresh(), to: Cache

  @doc """
  Returns the effective upstream PostgREST credential of an API key's config:
  its `:pgrst_credential`, else the tenant's `pgrst_api_key`.
  """
  @spec pgrst_credential(map()) :: String.t()
  def pgrst_credential(config), do: config[:pgrst_credential] || config.pgrst_api_key
end
