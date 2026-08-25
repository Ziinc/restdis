defmodule Restdis.Cache.TenantInvalidator do
  @moduledoc """
  Invalidator a WAL follower calls when a tenant's configuration row changes.

  Exposes `invalidate/1` by convention rather than declaring a `@behaviour`, so
  the cache never depends on the caller.
  """

  @doc """
  Flushes every cache layer of `tenant_id` after its config changed.
  """
  @spec invalidate(String.t()) :: :ok
  def invalidate(tenant_id) do
    Restdis.Cache.flush_tenant(tenant_id)
  end
end
