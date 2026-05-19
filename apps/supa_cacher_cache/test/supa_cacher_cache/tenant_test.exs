defmodule SupaCacherCache.TenantTest do
  use ExUnit.Case, async: false

  alias SupaCacherCache.DiskCache
  alias SupaCacherCache.Key
  alias SupaCacherCache.TenantRegistry
  alias SupaCacherCache.TenantSupervisor

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

    SupaCacherCache.flush_tenant(tenant_id)
  end

  test "flush_tenant wipes ETS and disk" do
    tenant_id = "flush_#{System.unique_integer([:positive])}"
    key = Key.build(:table, "orders", %{})

    TenantSupervisor.ensure_started(tenant_id)
    DiskCache.put(tenant_id, key, "data")
    DiskCache.get(tenant_id, key)

    SupaCacherCache.flush_tenant(tenant_id)
    Process.sleep(50)

    TenantSupervisor.ensure_started(tenant_id)
    assert :miss = DiskCache.get(tenant_id, key)

    SupaCacherCache.flush_tenant(tenant_id)
  end

  test "invalidate_by_row deletes matched cache keys from both layers" do
    tenant_id = "inv_#{System.unique_integer([:positive])}"
    key = Key.build(:table, "products", %{"select" => "*"})
    value = [%{"id" => 42, "name" => "Gadget"}]

    SupaCacherCache.put(tenant_id, key, value)
    assert {:ok, _} = SupaCacherCache.get(tenant_id, key)

    SupaCacherCache.invalidate_by_row(tenant_id, "products", 42)
    Process.sleep(50)

    assert :miss = SupaCacherCache.get(tenant_id, key)
    assert :miss = DiskCache.get(tenant_id, key)

    SupaCacherCache.flush_tenant(tenant_id)
  end
end
