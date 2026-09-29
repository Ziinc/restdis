defmodule Restdis.Cache.HotCacheTest do
  use ExUnit.Case, async: false

  alias Restdis.Cache.HotCache
  alias Restdis.Cache.HotCache.Transport.Distribution
  alias Restdis.Cache.Key
  alias Restdis.Cache.TestUtils
  alias Restdis.Cache.TestUtils.RecordingHotCacheTransport

  @propagate_at 5
  @ttl_ms 5 * 60 * 1_000

  setup do
    previous_transport = Application.get_env(:restdis, :hot_cache_transport)
    previous_max_entries = Application.get_env(:restdis, :hot_cache_max_entries)

    TestUtils.put_hot_cache_transport(RecordingHotCacheTransport)
    TestUtils.capture_hot_cache(self())

    tenant_id = "hot_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      TestUtils.stop_capturing_hot_cache()
      restore_env(:hot_cache_transport, previous_transport)
      restore_env(:hot_cache_max_entries, previous_max_entries)
      HotCache.flush()
    end)

    {:ok, tenant_id: tenant_id}
  end

  describe "observe/4" do
    test "stores the value locally on the very first access", %{tenant_id: tenant_id} do
      key = Key.build(:table, "widgets", %{})

      HotCache.observe(tenant_id, key, "v", :infinity)

      assert {:ok, "v"} = HotCache.get(tenant_id, key)
      refute_receive {:gossiped, _}, 100
    end

    test "does not gossip before the propagation count is reached", %{tenant_id: tenant_id} do
      key = Key.build(:table, "widgets", %{})

      for _ <- 1..(@propagate_at - 1), do: HotCache.observe(tenant_id, key, "v", :infinity)

      assert {:ok, "v"} = HotCache.get(tenant_id, key)
      refute_receive {:gossiped, _}, 100
    end

    test "gossips the value once the access count reaches the propagation threshold", %{
      tenant_id: tenant_id
    } do
      key = Key.build(:table, "widgets", %{})

      for _ <- 1..@propagate_at, do: HotCache.observe(tenant_id, key, "v", :infinity)

      assert {:ok, "v"} = HotCache.get(tenant_id, key)
      assert_receive {:gossiped, {:sc_hot_cache_put, ^tenant_id, ^key, "v", ttl_ms}}
      assert ttl_ms == @ttl_ms
      refute_receive {:gossiped, _}, 100
    end

    test "stores the entry with a five minute TTL", %{tenant_id: tenant_id} do
      key = Key.build(:table, "widgets", %{})

      HotCache.observe(tenant_id, key, "v", :infinity)

      assert {:ok, "v"} = HotCache.get(tenant_id, key)
    end

    test "never stores the entry past the underlying entry's remaining TTL", %{
      tenant_id: tenant_id
    } do
      key = Key.build(:table, "widgets", %{})

      HotCache.observe(tenant_id, key, "v", 50)
      assert {:ok, "v"} = HotCache.get(tenant_id, key)
      Process.sleep(100)

      assert :miss = HotCache.get(tenant_id, key)
    end

    test "gossips the underlying entry's remaining TTL when shorter than five minutes", %{
      tenant_id: tenant_id
    } do
      key = Key.build(:table, "widgets", %{})

      for _ <- 1..@propagate_at, do: HotCache.observe(tenant_id, key, "v", 1_000)

      assert_receive {:gossiped, {:sc_hot_cache_put, ^tenant_id, ^key, "v", ttl_ms}}
      assert ttl_ms <= 1_000
    end

    test "never holds more entries than the configured cap", %{tenant_id: tenant_id} do
      Application.put_env(:restdis, :hot_cache_max_entries, 3)

      for i <- 1..10 do
        HotCache.observe(tenant_id, Key.build(:table, "widgets", %{"i" => i}), i, :infinity)
        assert HotCache.size() <= 3
      end

      last = Key.build(:table, "widgets", %{"i" => 10})
      assert {:ok, 10} = HotCache.get(tenant_id, last)
    end

    test "an unrelated key does not share the propagated key's count", %{tenant_id: tenant_id} do
      key1 = Key.build(:table, "widgets", %{"a" => "1"})
      key2 = Key.build(:table, "widgets", %{"a" => "2"})

      for _ <- 1..@propagate_at, do: HotCache.observe(tenant_id, key1, "v1", :infinity)

      assert {:ok, "v1"} = HotCache.get(tenant_id, key1)
      assert :miss = HotCache.get(tenant_id, key2)
    end
  end

  describe "delete/3" do
    test "removes a stored entry and gossips the delete", %{tenant_id: tenant_id} do
      key = Key.build(:table, "widgets", %{})
      HotCache.observe(tenant_id, key, "v", :infinity)

      assert :ok = HotCache.delete(tenant_id, key)

      assert :miss = HotCache.get(tenant_id, key)
      assert_receive {:gossiped, {:sc_hot_cache_delete, ^tenant_id, ^key}}
    end

    test "a gossiped delete does not re-broadcast", %{tenant_id: tenant_id} do
      key = Key.build(:table, "widgets", %{})
      HotCache.apply_gossip_put(tenant_id, key, "v", @ttl_ms)

      assert :ok = HotCache.apply_gossip_delete(tenant_id, key)

      assert :miss = HotCache.get(tenant_id, key)
      refute_receive {:gossiped, _}, 100
    end
  end

  describe "delete_local/2" do
    test "removes a stored entry without gossiping", %{tenant_id: tenant_id} do
      key = Key.build(:table, "widgets", %{})
      HotCache.observe(tenant_id, key, "v", :infinity)

      assert :ok = HotCache.delete_local(tenant_id, key)

      assert :miss = HotCache.get(tenant_id, key)
      refute_receive {:gossiped, _}, 100
    end
  end

  describe "delete_tenant/2" do
    test "removes every entry of the tenant and gossips the delete", %{tenant_id: tenant_id} do
      key1 = Key.build(:table, "widgets", %{})
      key2 = Key.build(:table, "gadgets", %{})
      other = "other_#{tenant_id}"
      HotCache.observe(tenant_id, key1, "v1", :infinity)
      HotCache.observe(tenant_id, key2, "v2", :infinity)
      HotCache.observe(other, key1, "o", :infinity)

      assert :ok = HotCache.delete_tenant(tenant_id)

      assert :miss = HotCache.get(tenant_id, key1)
      assert :miss = HotCache.get(tenant_id, key2)
      assert {:ok, "o"} = HotCache.get(other, key1)
      assert_receive {:gossiped, {:sc_hot_cache_delete_tenant, ^tenant_id}}
    end

    test "a gossiped tenant delete does not re-broadcast", %{tenant_id: tenant_id} do
      key = Key.build(:table, "widgets", %{})
      HotCache.apply_gossip_put(tenant_id, key, "v", @ttl_ms)

      GenServer.cast(HotCache.Receiver, {:sc_hot_cache_delete_tenant, tenant_id})
      :ok = GenServer.call(HotCache.Receiver, :sync)

      assert :miss = HotCache.get(tenant_id, key)
      refute_receive {:gossiped, _}, 100
    end
  end

  describe "apply_gossip_put/4" do
    test "stores the entry locally without re-broadcasting", %{tenant_id: tenant_id} do
      key = Key.build(:table, "widgets", %{})

      assert :ok = HotCache.apply_gossip_put(tenant_id, key, "v", @ttl_ms)

      assert {:ok, "v"} = HotCache.get(tenant_id, key)
      refute_receive {:gossiped, _}, 100
    end

    test "an expired entry reads as a miss", %{tenant_id: tenant_id} do
      key = Key.build(:table, "widgets", %{})

      assert :ok = HotCache.apply_gossip_put(tenant_id, key, "v", -1)

      assert :miss = HotCache.get(tenant_id, key)
    end
  end

  describe "receiver process" do
    test "applies an inbound gossip put", %{tenant_id: tenant_id} do
      key = Key.build(:table, "widgets", %{})

      GenServer.cast(
        HotCache.Receiver,
        {:sc_hot_cache_put, tenant_id, key, "v", @ttl_ms}
      )

      :ok = GenServer.call(HotCache.Receiver, :sync)

      assert {:ok, "v"} = HotCache.get(tenant_id, key)
    end
  end

  describe "distribution transport" do
    test "broadcasting with no connected peers succeeds" do
      key = Key.build(:table, "widgets", %{})

      assert :ok = Distribution.broadcast({:sc_hot_cache_delete, "t", key})
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:restdis, key)
  defp restore_env(key, value), do: Application.put_env(:restdis, key, value)
end
