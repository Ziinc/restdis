defmodule Restdis.Cache.TenantRegistry do
  @moduledoc """
  Registry resolving a tenant id to its running tenant aggregate process.
  """

  @registry __MODULE__

  @type role :: :tenant | :query_cache | :disk_cache | :reverse_index

  @doc """
  Returns the `:via` tuple naming the `role` process of `tenant_id`.
  """
  @spec via(String.t(), role()) :: {:via, Registry, {module(), {String.t(), role()}}}
  def via(tenant_id, role) do
    {:via, Registry, {@registry, {tenant_id, role}}}
  end

  @doc """
  Returns the pid of the `role` process of `tenant_id`, or nil.
  """
  @spec whereis(String.t(), role()) :: pid() | nil
  def whereis(tenant_id, role) do
    case Registry.lookup(@registry, {tenant_id, role}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end
end
