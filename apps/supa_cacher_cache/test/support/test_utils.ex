defmodule SupaCacherCache.TestUtils do
  @moduledoc """
  Shared test helpers for the `supa_cacher_cache` bounded context.
  """

  alias SupaCacherCache.TenantSupervisor

  @target_key :sc_test_replication_target

  @spec start_tenant(String.t()) :: String.t()
  def start_tenant(prefix) do
    tenant_id = "#{prefix}_#{System.unique_integer([:positive])}"
    TenantSupervisor.ensure_started(tenant_id)
    tenant_id
  end

  @spec capture_replication(pid()) :: :ok
  def capture_replication(pid) do
    :persistent_term.put(@target_key, pid)
    :ok
  end

  @spec stop_capturing_replication() :: :ok
  def stop_capturing_replication do
    :persistent_term.erase(@target_key)
    :ok
  end

  @spec replication_target() :: pid() | nil
  def replication_target do
    :persistent_term.get(@target_key, nil)
  end

  @spec put_transport(module() | nil) :: :ok
  def put_transport(transport) do
    Application.put_env(:supa_cacher_cache, :replication_transport, transport)
  end
end
