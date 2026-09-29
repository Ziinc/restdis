defmodule Restdis.Cache.TenantTest do
  use ExUnit.Case, async: false

  alias Restdis.Cache.DiskCache
  alias Restdis.Cache.Key
  alias Restdis.Cache.QueryCache
  alias Restdis.Cache.TenantRegistry
  alias Restdis.Cache.TenantSupervisor

  test "ensure_started uses the Registry fast path once the tenant is warm" do
    tenant_id = "ensure_started_fast_path_#{System.unique_integer([:positive])}"

    TenantSupervisor.ensure_started(Restdis.Cache, tenant_id)
    reverse_index_pid = TenantRegistry.whereis(Restdis.Cache, tenant_id, :reverse_index)
    tenant_sup_pid = TenantRegistry.whereis(Restdis.Cache, tenant_id, :tenant)
    assert is_pid(reverse_index_pid)

    :erlang.trace(Process.whereis(TenantSupervisor.supervisor_name(Restdis.Cache)), true, [
      :receive
    ])

    TenantSupervisor.ensure_started(Restdis.Cache, tenant_id)

    refute_receive {:trace, _pid, :receive, {:"$gen_call", _from, {:start_child, _}}}, 100

    :erlang.trace(Process.whereis(TenantSupervisor.supervisor_name(Restdis.Cache)), false, [
      :receive
    ])

    assert TenantRegistry.whereis(Restdis.Cache, tenant_id, :tenant) == tenant_sup_pid
    assert TenantRegistry.whereis(Restdis.Cache, tenant_id, :reverse_index) == reverse_index_pid

    Restdis.Cache.flush_tenant(tenant_id)
  end

  @tag :restart
  test "CubDB serves warm data after tenant supervisor restart" do
    tenant_id = "restart_#{System.unique_integer([:positive])}"
    key = Key.build(:table, "products", %{"id" => "eq.1"})
    value = %{"id" => 1, "name" => "Widget"}

    TenantSupervisor.ensure_started(Restdis.Cache, tenant_id)
    DiskCache.put(tenant_id, key, value, name: Restdis.Cache)

    pid = TenantRegistry.whereis(Restdis.Cache, tenant_id, :tenant)
    Supervisor.stop(pid, :normal)
    Process.sleep(50)

    TenantSupervisor.ensure_started(Restdis.Cache, tenant_id)
    assert {:ok, ^value} = DiskCache.get(Restdis.Cache, tenant_id, key)

    Restdis.Cache.flush_tenant(tenant_id)
  end

  test "flush_tenant wipes ETS and disk" do
    tenant_id = "flush_#{System.unique_integer([:positive])}"
    key = Key.build(:table, "orders", %{})

    TenantSupervisor.ensure_started(Restdis.Cache, tenant_id)
    DiskCache.put(tenant_id, key, "data", name: Restdis.Cache)
    DiskCache.get(Restdis.Cache, tenant_id, key)

    Restdis.Cache.flush_tenant(tenant_id)
    Process.sleep(50)

    TenantSupervisor.ensure_started(Restdis.Cache, tenant_id)
    assert :miss = DiskCache.get(Restdis.Cache, tenant_id, key)

    Restdis.Cache.flush_tenant(tenant_id)
  end

  test "peek reports a miss once a ttl_ms entry expires, instead of serving stale disk data" do
    tenant_id = "ttl_#{System.unique_integer([:positive])}"
    key = Key.build(:table, "products", %{})
    value = [%{"id" => 1}]

    Restdis.Cache.put(tenant_id, key, value, ttl_ms: -1)

    assert :miss = Restdis.Cache.peek(tenant_id, key)
    assert :miss = DiskCache.get(Restdis.Cache, tenant_id, key)

    Restdis.Cache.flush_tenant(tenant_id)
  end

  test "peek re-promotes a still-live ttl_ms entry from disk with its remaining ttl" do
    tenant_id = "ttl_live_#{System.unique_integer([:positive])}"
    key = Key.build(:table, "products", %{})
    value = [%{"id" => 1}]

    Restdis.Cache.put(tenant_id, key, value, ttl_ms: 60_000)
    QueryCache.delete(Restdis.Cache, tenant_id, key)

    assert {:ok, ^value} = Restdis.Cache.peek(tenant_id, key)
    assert {:ok, ^value} = QueryCache.get(Restdis.Cache, tenant_id, key)

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
    assert :miss = DiskCache.get(Restdis.Cache, tenant_id, key)

    Restdis.Cache.flush_tenant(tenant_id)
  end

  test "invalidate_by_row and invalidate_lists reach entries written before a tenant restart" do
    tenant_id = "ri_restart_#{System.unique_integer([:positive])}"
    row_key = Key.build(:table, "widgets", %{"id" => "eq.11"})
    list_key = Key.build(:table, "widgets", %{"select" => "*"})

    :ok = Restdis.Cache.put(tenant_id, row_key, %{"id" => 11, "name" => "w11"}, ttl_ms: 60_000)
    :ok = Restdis.Cache.put(tenant_id, list_key, [%{"id" => 12}], persist: true)

    restart_tenant(tenant_id)

    Restdis.Cache.invalidate_by_row(tenant_id, "widgets", 11)
    Restdis.Cache.invalidate_lists(tenant_id, "widgets")

    assert :miss = Restdis.Cache.peek(tenant_id, row_key)
    assert :miss = Restdis.Cache.peek(tenant_id, list_key)

    Restdis.Cache.flush_tenant(tenant_id)
  end

  test "invalidation still reaches cached entries after the reverse index process is killed" do
    tenant_id = "ri_kill_#{System.unique_integer([:positive])}"
    row_key = Key.build(:table, "widgets", %{"id" => "eq.11"})
    list_key = Key.build(:table, "widgets", %{"select" => "*"})

    :ok = Restdis.Cache.put(tenant_id, row_key, %{"id" => 11, "name" => "w11"})
    :ok = Restdis.Cache.put(tenant_id, list_key, [%{"id" => 12}])

    reverse_index_pid = TenantRegistry.whereis(Restdis.Cache, tenant_id, :reverse_index)
    Process.exit(reverse_index_pid, :kill)
    await_restarted(tenant_id, :reverse_index, reverse_index_pid)

    Restdis.Cache.invalidate_by_row(tenant_id, "widgets", 11)
    Restdis.Cache.invalidate_lists(tenant_id, "widgets")

    assert :miss = Restdis.Cache.peek(tenant_id, row_key)
    assert :miss = Restdis.Cache.peek(tenant_id, list_key)

    Restdis.Cache.flush_tenant(tenant_id)
  end

  test "an old-format disk entry without reverse index metadata is dropped on tenant restart" do
    tenant_id = "ri_legacy_#{System.unique_integer([:positive])}"
    key = Key.build(:table, "widgets", %{"id" => "eq.11"})

    TenantSupervisor.ensure_started(Restdis.Cache, tenant_id)
    cubdb = TenantRegistry.get_value(Restdis.Cache, tenant_id, :dc_cubdb)

    legacy_entry =
      {:v1, %{value: %{"id" => 11}, persist: true, inserted_at: 0, expires_at: :infinity}}

    :ok = CubDB.put(cubdb, key, legacy_entry)

    restart_tenant(tenant_id)

    assert :miss = Restdis.Cache.peek(tenant_id, key)
    assert Restdis.Cache.persist_count(tenant_id) == 0

    Restdis.Cache.flush_tenant(tenant_id)
  end

  defp restart_tenant(tenant_id) do
    pid = TenantRegistry.whereis(Restdis.Cache, tenant_id, :tenant)
    Supervisor.stop(pid, :normal)
    TenantSupervisor.ensure_started(Restdis.Cache, tenant_id)
  end

  defp await_restarted(tenant_id, role, old_pid) do
    case TenantRegistry.whereis(Restdis.Cache, tenant_id, role) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _ ->
        Process.sleep(10)
        await_restarted(tenant_id, role, old_pid)
    end
  end
end
