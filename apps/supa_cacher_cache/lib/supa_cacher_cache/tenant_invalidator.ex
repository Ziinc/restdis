defmodule SupaCacherCache.TenantInvalidator do
  @moduledoc false

  # Implements SupaCacherBuster.TenantConfigInvalidator by convention
  # (no @behaviour to avoid a reverse umbrella dep on supa_cacher_buster).

  @spec invalidate(String.t()) :: :ok
  def invalidate(tenant_id) do
    SupaCacherCache.flush_tenant(tenant_id)
  end
end
