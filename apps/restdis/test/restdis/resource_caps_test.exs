defmodule Restdis.Cache.ResourceCapsTest do
  use ExUnit.Case, async: false

  alias Restdis.Cache.DiskCache
  alias Restdis.Cache.Key
  alias Restdis.Cache.QueryCache
  alias Restdis.Cache.TenantSupervisor

  setup do
    tenant_id = "caps_#{System.unique_integer([:positive])}"
    TenantSupervisor.ensure_started(tenant_id)
    on_exit(fn -> Restdis.Cache.flush_tenant(tenant_id) end)
    {:ok, tenant_id: tenant_id}
  end

  describe "ETS memory cap / LRU eviction" do
    test "default cap is 500 MB unless overridden" do
      assert Application.get_env(:restdis, :ets_cap_bytes, 500 * 1024 * 1024) ==
               500 * 1024 * 1024
    end

    test "eviction is configurable via Application env and evicts the LRU entry", %{
      tenant_id: tenant_id
    } do
      key1 = Key.build(:table, "t1", %{"a" => 1})
      key2 = Key.build(:table, "t2", %{"a" => 2})
      key3 = Key.build(:table, "t3", %{"a" => 3})
      value = String.duplicate("x", 1000)

      QueryCache.put(tenant_id, key1, value)
      mem_after_one = QueryCache.memory_bytes(tenant_id)
      QueryCache.put(tenant_id, key2, value)
      mem_after_two = QueryCache.memory_bytes(tenant_id)
      marginal = mem_after_two - mem_after_one

      # enough room for two entries, but not a third
      cap = mem_after_two + div(marginal, 2)
      Application.put_env(:restdis, :ets_cap_bytes, cap)
      on_exit(fn -> Application.delete_env(:restdis, :ets_cap_bytes) end)

      # touch key1 so it becomes more-recently-used than key2
      assert {:ok, ^value} = QueryCache.get(tenant_id, key1)

      # inserting key3 pushes memory over the cap; key2 (LRU) should be evicted
      QueryCache.put(tenant_id, key3, value)

      assert {:ok, ^value} = QueryCache.get(tenant_id, key1)
      assert {:ok, ^value} = QueryCache.get(tenant_id, key3)
      assert :miss = QueryCache.get(tenant_id, key2)
      assert QueryCache.memory_bytes(tenant_id) <= cap
    end

    test "emits telemetry on eviction", %{tenant_id: tenant_id} do
      key1 = Key.build(:table, "e1", %{"a" => 1})
      key2 = Key.build(:table, "e2", %{"a" => 2})
      value = String.duplicate("y", 1000)

      QueryCache.put(tenant_id, key1, value)
      mem_after_one = QueryCache.memory_bytes(tenant_id)
      cap = mem_after_one + 1

      test_pid = self()

      handler_id = "ets-evict-handler-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:restdis, :cache, :ets_evict],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:ets_evict, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Application.put_env(:restdis, :ets_cap_bytes, cap)
      on_exit(fn -> Application.delete_env(:restdis, :ets_cap_bytes) end)

      QueryCache.put(tenant_id, key2, value)

      assert_receive {:ets_evict, %{count: 1}, %{tenant_id: ^tenant_id}}, 1000
    end
  end

  describe "CubDB disk cap eviction" do
    test "default cap is 500 MB unless overridden" do
      assert Application.get_env(:restdis, :cubdb_cap_bytes, 500 * 1024 * 1024) ==
               500 * 1024 * 1024
    end

    test "evicts oldest non-persist entries first, protecting persisted entries", %{
      tenant_id: tenant_id
    } do
      persisted_key = Key.build(:table, "protected", %{})
      old_key = Key.build(:table, "old", %{})
      new_key = Key.build(:table, "new", %{})
      value = String.duplicate("z", 2000)

      DiskCache.put(tenant_id, persisted_key, value, persist: true)
      DiskCache.put(tenant_id, old_key, value)

      size_after_two = DiskCache.disk_size_bytes(tenant_id)
      cap = round(size_after_two * 1.3)
      Application.put_env(:restdis, :cubdb_cap_bytes, cap)
      on_exit(fn -> Application.delete_env(:restdis, :cubdb_cap_bytes) end)

      DiskCache.put(tenant_id, new_key, value)

      assert {:ok, ^value} = DiskCache.get(tenant_id, persisted_key)
      assert {:ok, ^value} = DiskCache.get(tenant_id, new_key)
      assert :miss = DiskCache.get(tenant_id, old_key)
    end

    test "emits telemetry on eviction", %{tenant_id: tenant_id} do
      old_key = Key.build(:table, "eold", %{})
      new_key = Key.build(:table, "enew", %{})
      value = String.duplicate("q", 2000)

      DiskCache.put(tenant_id, old_key, value)
      size_after_one = DiskCache.disk_size_bytes(tenant_id)
      cap = round(size_after_one * 1.3)
      Application.put_env(:restdis, :cubdb_cap_bytes, cap)
      on_exit(fn -> Application.delete_env(:restdis, :cubdb_cap_bytes) end)

      test_pid = self()
      handler_id = "cubdb-evict-handler-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:restdis, :cache, :cubdb_evict],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:cubdb_evict, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      DiskCache.put(tenant_id, new_key, value)

      assert_receive {:cubdb_evict, %{count: 1}, %{tenant_id: ^tenant_id}}, 1000
    end
  end
end
