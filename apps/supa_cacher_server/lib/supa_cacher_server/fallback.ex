defmodule SupaCacherServer.Fallback do
  @moduledoc """
  Direct PostgREST fetch used when the owning node is unreachable (PRD Phase 6, step 7).

  Routing gives up after one second. Rather than failing the request, the
  receiving node fetches from PostgREST itself and answers from the response,
  bypassing the cache entirely so the unreachable owner stays authoritative.
  """

  alias Restdis.Cache.Key
  alias SupaCacherServer.PostgREST.Fetcher
  alias SupaCacherServer.TenantConfig

  @doc """
  Fetches `key` straight from PostgREST for `tenant_id`.
  """
  @spec fetch(String.t(), Key.t()) :: {:ok, term()} | {:error, term()}
  def fetch(tenant_id, key) do
    :telemetry.execute([:supa_cacher_server, :cluster, :fallback], %{count: 1}, %{
      tenant_id: tenant_id
    })

    with {:ok, config} <- TenantConfig.lookup_by_tenant_id(tenant_id) do
      Fetcher.fetch(tenant_id, key, config)
    end
  end
end
