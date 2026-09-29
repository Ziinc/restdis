defmodule RestdisServer.Fallback do
  @moduledoc """
  Direct PostgREST fetch used when the owning node is unreachable (PRD Phase 6, step 7).

  Routing gives up after one second. Rather than failing the request, the
  receiving node fetches from PostgREST itself and answers from the response,
  bypassing the cache entirely so the unreachable owner stays authoritative.
  """

  alias Restdis.Cache.Key
  alias RestdisServer.PostgREST.Fetcher
  alias RestdisServer.TenantConfig

  @doc """
  Fetches `key` straight from PostgREST for `tenant_id`, using the requesting
  connection's `credential` when the key has none recorded.
  """
  @spec fetch(String.t(), Key.t(), String.t() | nil) :: {:ok, term()} | {:error, term()}
  def fetch(tenant_id, key, credential) do
    :telemetry.execute([:restdis_server, :cluster, :fallback], %{count: 1}, %{
      tenant_id: tenant_id
    })

    with {:ok, config} <- TenantConfig.lookup_by_tenant_id(tenant_id) do
      Fetcher.fetch(tenant_id, key, Map.put(config, :pgrst_credential, credential))
    end
  end
end
