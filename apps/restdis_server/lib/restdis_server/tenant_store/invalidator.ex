defmodule RestdisServer.TenantStore.Invalidator do
  @moduledoc """
  Implements `RestdisBuster.TenantConfigInvalidator` by convention.

  No `@behaviour` is declared, to avoid a reverse umbrella dependency on
  `restdis_buster`.
  """

  alias RestdisServer.Rewarm
  alias RestdisServer.TenantConfig

  @doc """
  Drops the cached configuration of `tenant_id` and stops its rewarms.
  """
  @spec invalidate(String.t()) :: :ok
  def invalidate(tenant_id) do
    TenantConfig.invalidate(tenant_id)
    Rewarm.stop_tenant(tenant_id)
  end
end
