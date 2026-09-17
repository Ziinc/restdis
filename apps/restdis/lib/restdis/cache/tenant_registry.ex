defmodule Restdis.Cache.TenantRegistry do
  @moduledoc """
  Registry resolving a tenant id to its running tenant aggregate process.

  Scoped by cache instance `name` (the same `:name` passed to
  `Restdis.Cache.Supervisor.start_link/1`), so two instances mounted in the same
  VM each get their own `Registry` process and never resolve each other's
  tenants.
  """

  @type role :: :tenant | :query_cache | :disk_cache | :reverse_index

  @doc """
  Returns the registered name of the `Registry` process belonging to instance `name`.
  """
  @spec registry_name(atom()) :: atom()
  def registry_name(name), do: Module.concat(name, __MODULE__)

  @doc """
  Returns the `:via` tuple naming the `role` process of `tenant_id` under instance `name`.
  """
  @spec via(atom(), String.t(), role()) :: {:via, Registry, {module(), {String.t(), role()}}}
  def via(name, tenant_id, role) do
    {:via, Registry, {registry_name(name), {tenant_id, role}}}
  end

  @doc """
  Returns the ids of the tenant aggregates running on this node for instance `name`.
  """
  @spec local_tenants(atom()) :: [String.t()]
  def local_tenants(name) do
    Registry.select(registry_name(name), [
      {{{:"$1", :tenant}, :_, :_}, [], [:"$1"]}
    ])
  end

  @doc """
  Returns the pid of the `role` process of `tenant_id` under instance `name`, or nil.
  """
  @spec whereis(atom(), String.t(), role()) :: pid() | nil
  def whereis(name, tenant_id, role) do
    case Registry.lookup(registry_name(name), {tenant_id, role}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Registers the calling process under `{tenant_id, key}` with `value`, scoped to instance `name`.

  Used to publish per-tenant shared state (an ETS table id, a counters
  ref, ...) that must be readable from any process without going through
  `persistent_term`, whose writes trigger a global GC pass on every
  change. Registry registrations live in a regular ETS table and are
  automatically removed when the registering process exits, so tenant
  churn never pays a global-GC cost and never leaves a stale entry
  behind.
  """
  @spec put_value(atom(), String.t(), term(), term()) :: :ok
  def put_value(name, tenant_id, key, value) do
    {:ok, _owner} = Registry.register(registry_name(name), {tenant_id, key}, value)
    :ok
  end

  @doc """
  Returns the value registered under `{tenant_id, key}` for instance `name`, or `default`.
  """
  @spec get_value(atom(), String.t(), term(), term()) :: term()
  def get_value(name, tenant_id, key, default \\ nil) do
    case Registry.lookup(registry_name(name), {tenant_id, key}) do
      [{_pid, value}] -> value
      [] -> default
    end
  end
end
