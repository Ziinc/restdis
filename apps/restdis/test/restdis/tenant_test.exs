defmodule Restdis.Cache.TenantTest do
  use ExUnit.Case, async: false

  alias Restdis.Cache.DiskCache
  alias Restdis.Cache.Key
  alias Restdis.Cache.TenantRegistry
  alias Restdis.Cache.TenantSupervisor

  test "ensure_started uses the Registry fast path once the tenant is warm" do
    tenant_id = "ensure_started_fast_path_#{System.unique_integer([:positive])}"

    TenantSupervisor.ensure_started(tenant_id)
    reverse_index_pid = TenantRegistry.whereis(tenant_id, :reverse_index)
    tenant_sup_pid = TenantRegistry.whereis(tenant_id, :tenant)
    assert is_pid(reverse_index_pid)

    :erlang.trace(Process.whereis(TenantSupervisor), true, [:receive])

    TenantSupervisor.ensure_started(tenant_id)

    refute_receive {:trace, _pid, :receive, {:"$gen_call", _from, {:start_child, _}}}, 100

    :erlang.trace(Process.whereis(TenantSupervisor), false, [:receive])

    assert TenantRegistry.whereis(tenant_id, :tenant) == tenant_sup_pid
    assert TenantRegistry.whereis(tenant_id, :reverse_index) == reverse_index_pid

    Restdis.Cache.flush_tenant(tenant_id)
  end

  @tag :restart
  test "CubDB serves warm data after tenant supervisor restart" do
    tenant_id = "restart_#{System.unique_integer([:positive])}"
    key = Key.build(:table, "products", %{"id" => "eq.1"})
    value = %{"id" => 1, "name" => "Widget"}

    TenantSupervisor.ensure_started(tenant_id)
    DiskCache.put(tenant_id, key, value)

    pid = TenantRegistry.whereis(tenant_id, :tenant)
    Supervisor.stop(pid, :normal)
    Process.sleep(50)

    TenantSupervisor.ensure_started(tenant_id)
    assert {:ok, ^value} = DiskCache.get(tenant_id, key)

    Restdis.Cache.flush_tenant(tenant_id)
  end

  test "flush_tenant wipes ETS and disk" do
    tenant_id = "flush_#{System.unique_integer([:positive])}"
    key = Key.build(:table, "orders", %{})

    TenantSupervisor.ensure_started(tenant_id)
    DiskCache.put(tenant_id, key, "data")
    DiskCache.get(tenant_id, key)

    Restdis.Cache.flush_tenant(tenant_id)
    Process.sleep(50)

    TenantSupervisor.ensure_started(tenant_id)
    assert :miss = DiskCache.get(tenant_id, key)

    Restdis.Cache.flush_tenant(tenant_id)
  end

  test "invalidate_by_row deletes matched cache keys from both layers" do
    tenant_id = "inv_#{System.unique_integer([:positive])}"
    key = Key.build(:table, "products", %{"select" => "*"})
    value = [%{"id" => 42, "name" => "Gadget"}]

    Restdis.Cache.put(tenant_id, key, value)
    assert {:ok, _} = Restdis.Cache.get(tenant_id, key)

    Restdis.Cache.invalidate_by_row(tenant_id, "products", 42)
    Process.sleep(50)

    assert :miss = Restdis.Cache.get(tenant_id, key)
    assert :miss = DiskCache.get(tenant_id, key)

    Restdis.Cache.flush_tenant(tenant_id)
  end
end
