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
  Returns the ids of the tenant aggregates running on this node.
  """
  @spec local_tenants() :: [String.t()]
  def local_tenants do
    Registry.select(@registry, [
      {{{:"$1", :tenant}, :_, :_}, [], [:"$1"]}
    ])
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

  @doc """
  Registers the calling process under `{tenant_id, key}` with `value`.

  Used to publish per-tenant shared state (an ETS table id, a counters
  ref, ...) that must be readable from any process without going through
  `persistent_term`, whose writes trigger a global GC pass on every
  change. Registry registrations live in a regular ETS table and are
  automatically removed when the registering process exits, so tenant
  churn never pays a global-GC cost and never leaves a stale entry
  behind.
  """
  @spec put_value(String.t(), term(), term()) :: :ok
  def put_value(tenant_id, key, value) do
    {:ok, _owner} = Registry.register(@registry, {tenant_id, key}, value)
    :ok
  end

  @doc """
  Returns the value registered under `{tenant_id, key}`, or `default`.
  """
  @spec get_value(String.t(), term(), term()) :: term()
  def get_value(tenant_id, key, default \\ nil) do
    case Registry.lookup(@registry, {tenant_id, key}) do
      [{_pid, value}] -> value
      [] -> default
    end
  end
end
