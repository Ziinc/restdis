defmodule Restdis.Cache.HotCacheTest do
  use ExUnit.Case, async: false

  alias Restdis.Cache.HotCache
  alias Restdis.Cache.Key
  alias Restdis.Cache.TestUtils
  alias Restdis.Cache.TestUtils.RecordingHotCacheTransport

  setup do
    previous_transport = Application.get_env(:restdis, :hot_cache_transport)
    previous_threshold = Application.get_env(:restdis, :hot_cache_threshold)

    TestUtils.put_hot_cache_transport(RecordingHotCacheTransport)
    TestUtils.capture_hot_cache(self())
    Application.put_env(:restdis, :hot_cache_threshold, 3)

    tenant_id = "hot_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      TestUtils.stop_capturing_hot_cache()
      TestUtils.put_hot_cache_transport(previous_transport)
      Application.put_env(:restdis, :hot_cache_threshold, previous_threshold)
      HotCache.flush()
    end)

    {:ok, tenant_id: tenant_id}
  end

  describe "observe/3" do
    test "a key below the threshold is not promoted", %{tenant_id: tenant_id} do
      key = Key.build(:table, "widgets", %{})

      HotCache.observe(tenant_id, key, "v")
      HotCache.observe(tenant_id, key, "v")

      assert :miss = HotCache.get(tenant_id, key)
      refute_receive {:gossiped, _}, 100
    end

    test "crossing the threshold promotes and gossips the value once", %{tenant_id: tenant_id} do
      key = Key.build(:table, "widgets", %{})

      HotCache.observe(tenant_id, key, "v")
      HotCache.observe(tenant_id, key, "v")
      HotCache.observe(tenant_id, key, "v")

      assert {:ok, "v"} = HotCache.get(tenant_id, key)
      assert_receive {:gossiped, {:sc_hot_cache_put, ^tenant_id, ^key, "v", _ttl_ms}}
      refute_receive {:gossiped, _}, 100
    end

    test "an unrelated key does not share the promoted key's count", %{tenant_id: tenant_id} do
      key1 = Key.build(:table, "widgets", %{"a" => "1"})
      key2 = Key.build(:table, "widgets", %{"a" => "2"})

      HotCache.observe(tenant_id, key1, "v1")
      HotCache.observe(tenant_id, key1, "v1")
      HotCache.observe(tenant_id, key1, "v1")

      assert {:ok, "v1"} = HotCache.get(tenant_id, key1)
      assert :miss = HotCache.get(tenant_id, key2)
    end
  end

  describe "delete/3" do
    test "removes a promoted entry and gossips the delete", %{tenant_id: tenant_id} do
      key = Key.build(:table, "widgets", %{})
      HotCache.observe(tenant_id, key, "v")
      HotCache.observe(tenant_id, key, "v")
      HotCache.observe(tenant_id, key, "v")
      assert_receive {:gossiped, {:sc_hot_cache_put, _, _, _, _}}

      assert :ok = HotCache.delete(tenant_id, key)

      assert :miss = HotCache.get(tenant_id, key)
      assert_receive {:gossiped, {:sc_hot_cache_delete, ^tenant_id, ^key}}
    end

    test "a gossiped delete does not re-broadcast", %{tenant_id: tenant_id} do
      key = Key.build(:table, "widgets", %{})
      HotCache.apply_gossip_put(tenant_id, key, "v", 5_000)

      assert :ok = HotCache.apply_gossip_delete(tenant_id, key)

      assert :miss = HotCache.get(tenant_id, key)
      refute_receive {:gossiped, _}, 100
    end
  end

  describe "apply_gossip_put/4" do
    test "stores the entry locally without re-broadcasting", %{tenant_id: tenant_id} do
      key = Key.build(:table, "widgets", %{})

      assert :ok = HotCache.apply_gossip_put(tenant_id, key, "v", 5_000)

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
        {:sc_hot_cache_put, tenant_id, key, "v", 5_000}
      )

      :ok = GenServer.call(HotCache.Receiver, :sync)

      assert {:ok, "v"} = HotCache.get(tenant_id, key)
    end
  end

  describe "distribution transport" do
    test "broadcasting with no connected peers succeeds" do
      key = Key.build(:table, "widgets", %{})

      assert :ok =
               Restdis.Cache.HotCache.Transport.Distribution.broadcast(
                 {:sc_hot_cache_delete, "t", key}
               )
    end
  end
end
