defmodule SupaCacherCache.PersistTest do
  use ExUnit.Case, async: false

  alias SupaCacherCache.Key
  alias SupaCacherCache.TenantRegistry
  alias SupaCacherCache.TenantSupervisor

  setup do
    tenant_id = "persist_#{System.unique_integer([:positive])}"
    TenantSupervisor.ensure_started(tenant_id)
    on_exit(fn -> SupaCacherCache.flush_tenant(tenant_id) end)
    {:ok, tenant_id: tenant_id}
  end

  test "persist: true survives tenant supervisor restart", %{tenant_id: tenant_id} do
    key = Key.build(:table, "widgets", %{"select" => "*"})
    value = [%{"id" => 1}]

    assert :ok = SupaCacherCache.put(tenant_id, key, value, persist: true)

    pid = TenantRegistry.whereis(tenant_id, :tenant)
    Supervisor.stop(pid, :normal)
    Process.sleep(50)

    TenantSupervisor.ensure_started(tenant_id)
    assert {:ok, ^value} = SupaCacherCache.peek(tenant_id, key)
  end

  test "persist_count increments on persist put and decrements on delete", %{tenant_id: tenant_id} do
    key = Key.build(:table, "orders", %{})

    assert 0 = SupaCacherCache.persist_count(tenant_id)

    assert :ok = SupaCacherCache.put(tenant_id, key, "v1", persist: true)
    assert 1 = SupaCacherCache.persist_count(tenant_id)

    SupaCacherCache.delete(tenant_id, key)
    Process.sleep(50)

    assert 0 = SupaCacherCache.persist_count(tenant_id)
  end

  test "cap enforcement: 3rd persist put returns error and count stays at cap", %{
    tenant_id: tenant_id
  } do
    key1 = Key.build(:table, "t", %{"a" => "1"})
    key2 = Key.build(:table, "t", %{"a" => "2"})
    key3 = Key.build(:table, "t", %{"a" => "3"})

    assert :ok = SupaCacherCache.put(tenant_id, key1, "v1", persist: true, persist_cap: 2)
    assert :ok = SupaCacherCache.put(tenant_id, key2, "v2", persist: true, persist_cap: 2)

    assert {:error, :persist_cap} =
             SupaCacherCache.put(tenant_id, key3, "v3", persist: true, persist_cap: 2)

    assert 2 = SupaCacherCache.persist_count(tenant_id)
  end

  test "set_persist false→true increments count", %{tenant_id: tenant_id} do
    key = Key.build(:table, "products", %{})
    assert :ok = SupaCacherCache.put(tenant_id, key, "val")

    assert 0 = SupaCacherCache.persist_count(tenant_id)
    assert :ok = SupaCacherCache.set_persist(tenant_id, key, true)
    assert 1 = SupaCacherCache.persist_count(tenant_id)
  end

  test "set_persist true→false decrements count", %{tenant_id: tenant_id} do
    key = Key.build(:table, "products", %{})
    assert :ok = SupaCacherCache.put(tenant_id, key, "val", persist: true)
    assert 1 = SupaCacherCache.persist_count(tenant_id)

    assert :ok = SupaCacherCache.set_persist(tenant_id, key, false)
    assert 0 = SupaCacherCache.persist_count(tenant_id)
  end

  test "set_persist returns not_found for absent key", %{tenant_id: tenant_id} do
    key = Key.build(:table, "ghost", %{})
    assert {:error, :not_found} = SupaCacherCache.set_persist(tenant_id, key, true)
  end

  test "set_persist is a no-op if state already matches", %{tenant_id: tenant_id} do
    key = Key.build(:table, "noop", %{})
    assert :ok = SupaCacherCache.put(tenant_id, key, "v", persist: true)
    assert 1 = SupaCacherCache.persist_count(tenant_id)

    assert :ok = SupaCacherCache.set_persist(tenant_id, key, true)
    assert 1 = SupaCacherCache.persist_count(tenant_id)
  end

  test "persist_count is rebuilt from disk after supervisor restart", %{tenant_id: tenant_id} do
    key1 = Key.build(:table, "rebuild1", %{})
    key2 = Key.build(:table, "rebuild2", %{})
    key3 = Key.build(:table, "rebuild3", %{})

    assert :ok = SupaCacherCache.put(tenant_id, key1, "v1", persist: true)
    assert :ok = SupaCacherCache.put(tenant_id, key2, "v2", persist: true)
    assert :ok = SupaCacherCache.put(tenant_id, key3, "v3", persist: true)
    assert 3 = SupaCacherCache.persist_count(tenant_id)

    pid = TenantRegistry.whereis(tenant_id, :tenant)
    Supervisor.stop(pid, :normal)
    Process.sleep(50)

    TenantSupervisor.ensure_started(tenant_id)
    assert 3 = SupaCacherCache.persist_count(tenant_id)
  end

  test "legacy un-wrapped disk values still read correctly", %{tenant_id: tenant_id} do
    key = Key.build(:table, "legacy", %{})
    raw_value = %{"id" => 99, "name" => "old"}

    disk_cache_pid = TenantRegistry.whereis(tenant_id, :disk_cache)
    state = :sys.get_state(disk_cache_pid)
    cubdb = state.cubdb
    :ok = CubDB.put(cubdb, key, raw_value)

    assert {:ok, ^raw_value} = SupaCacherCache.peek(tenant_id, key)
  end
end
