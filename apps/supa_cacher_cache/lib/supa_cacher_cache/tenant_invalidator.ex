defmodule SupaCacherCache.TenantInvalidator do
  @moduledoc """
  Implements `SupaCacherBuster.TenantConfigInvalidator` by convention.

  No `@behaviour` is declared, to avoid a reverse umbrella dependency on
  `supa_cacher_buster`.
  """

  @doc """
  Flushes every cache layer of `tenant_id` after its config changed.
  """
  @spec invalidate(String.t()) :: :ok
  def invalidate(tenant_id) do
    SupaCacherCache.flush_tenant(tenant_id)
  end
end
