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
end
