defmodule SupaCacherCache.TenantRegistry do
  @moduledoc """
  Registry resolving a tenant id to its running tenant aggregate process.
  """

  @registry __MODULE__

  @type role :: :tenant | :query_cache | :disk_cache | :reverse_index

  @spec via(String.t(), role()) :: {:via, Registry, {module(), {String.t(), role()}}}
  def via(tenant_id, role) do
    {:via, Registry, {@registry, {tenant_id, role}}}
  end

  @spec whereis(String.t(), role()) :: pid() | nil
  def whereis(tenant_id, role) do
    case Registry.lookup(@registry, {tenant_id, role}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end
end
