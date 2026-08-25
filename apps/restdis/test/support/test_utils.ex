defmodule Restdis.Cache.TestUtils do
  @moduledoc """
  Shared test helpers for the `restdis` bounded context.
  """

  alias Restdis.Cache.Cluster
  alias Restdis.Cache.TenantSupervisor

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

  @spec add_cluster_node(node()) :: :ok
  def add_cluster_node(node) do
    send(Cluster, {:nodeup, node})
    Cluster.sync()
  end

  @spec remove_cluster_node(node()) :: :ok
  def remove_cluster_node(node) do
    send(Cluster, {:nodedown, node})
    Cluster.sync()
  end

  @spec tenant_owned_by(node()) :: String.t()
  def tenant_owned_by(node) do
    Enum.find_value(1..10_000, fn index ->
      tenant_id = "tenant_#{index}"
      if Cluster.owner(tenant_id) == node, do: tenant_id
    end)
  end

  @spec put_transport(module() | nil) :: :ok
  def put_transport(transport) do
    Application.put_env(:restdis, :replication_transport, transport)
  end
end
