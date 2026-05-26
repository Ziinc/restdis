defmodule SupaCacherServer.TenantStore.Invalidator do
  @moduledoc false

  # Implements SupaCacherBuster.TenantConfigInvalidator by convention
  # (no @behaviour to avoid a reverse umbrella dep on supa_cacher_buster).

  alias SupaCacherServer.Rewarm
  alias SupaCacherServer.TenantConfig

  @spec invalidate(String.t()) :: :ok
  def invalidate(tenant_id) do
    TenantConfig.invalidate(tenant_id)
    Rewarm.stop_tenant(tenant_id)
  end
end
