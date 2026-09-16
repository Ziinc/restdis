defmodule Restdis.Cache.ReplicationTest do
  use ExUnit.Case, async: false

  alias Restdis.Cache.InstanceConfig
  alias Restdis.Cache.Key
  alias Restdis.Cache.Replication
  alias Restdis.Cache.Replication.Transport.Distribution
  alias Restdis.Cache.TestUtils
  alias Restdis.Cache.TestUtils.RecordingTransport

  setup do
    previous = InstanceConfig.fetch!(Restdis.Cache).replication_transport
    TestUtils.put_transport(RecordingTransport)
    TestUtils.capture_replication(self())

    tenant_id = TestUtils.start_tenant("repl")

    on_exit(fn ->
      TestUtils.stop_capturing_replication()
      TestUtils.put_transport(previous)
      Restdis.Cache.flush_tenant(tenant_id)
    end)

    {:ok, tenant_id: tenant_id}
  end

  describe "broadcast on the originating node" do
    test "persist put broadcasts a put event carrying value and opts", %{tenant_id: tenant_id} do
      key = Key.build(:table, "widgets", %{"select" => "*"})
      value = [%{"id" => 1}]

      assert :ok = Restdis.Cache.put(tenant_id, key, value, persist: true)

      assert_receive {:replicated,
                      {:sc_replication, Restdis.Cache, ^tenant_id, {:put, ^key, ^value, opts}}}

      assert Keyword.fetch!(opts, :persist)
    end

    test "non-persist put does not broadcast", %{tenant_id: tenant_id} do
      key = Key.build(:table, "widgets", %{})

      assert :ok = Restdis.Cache.put(tenant_id, key, "v")

      refute_receive {:replicated, _}, 100
    end

    test "put rejected by the persist cap does not broadcast", %{tenant_id: tenant_id} do
      key1 = Key.build(:table, "t", %{"a" => "1"})
      key2 = Key.build(:table, "t", %{"a" => "2"})

      assert :ok = Restdis.Cache.put(tenant_id, key1, "v1", persist: true, persist_cap: 1)

      assert_receive {:replicated,
                      {:sc_replication, Restdis.Cache, ^tenant_id, {:put, ^key1, _, _}}}

      assert {:error, :persist_cap} =
               Restdis.Cache.put(tenant_id, key2, "v2", persist: true, persist_cap: 1)

      refute_receive {:replicated, _}, 100
    end

    test "delete of a persist entry broadcasts a delete event", %{tenant_id: tenant_id} do
      key = Key.build(:table, "orders", %{})
      assert :ok = Restdis.Cache.put(tenant_id, key, "v", persist: true)

      assert_receive {:replicated,
                      {:sc_replication, Restdis.Cache, ^tenant_id, {:put, ^key, _, _}}}

      assert :ok = Restdis.Cache.delete(tenant_id, key)

      assert_receive {:replicated, {:sc_replication, Restdis.Cache, ^tenant_id, {:delete, ^key}}}
    end

    test "delete of a non-persist entry does not broadcast", %{tenant_id: tenant_id} do
      key = Key.build(:table, "orders", %{})
      assert :ok = Restdis.Cache.put(tenant_id, key, "v")

      assert :ok = Restdis.Cache.delete(tenant_id, key)

      refute_receive {:replicated, _}, 100
    end

    test "set_persist false→true broadcasts a put event carrying the stored value", %{
      tenant_id: tenant_id
    } do
      key = Key.build(:table, "products", %{})
      value = %{"id" => 7}
      assert :ok = Restdis.Cache.put(tenant_id, key, value)

      assert :ok = Restdis.Cache.set_persist(tenant_id, key, true)

      assert_receive {:replicated,
                      {:sc_replication, Restdis.Cache, ^tenant_id, {:put, ^key, ^value, opts}}}

      assert Keyword.fetch!(opts, :persist)
    end

    test "set_persist true→false broadcasts a set_persist event", %{tenant_id: tenant_id} do
      key = Key.build(:table, "products", %{})
      assert :ok = Restdis.Cache.put(tenant_id, key, "v", persist: true)

      assert_receive {:replicated,
                      {:sc_replication, Restdis.Cache, ^tenant_id, {:put, ^key, _, _}}}

      assert :ok = Restdis.Cache.set_persist(tenant_id, key, false)

      assert_receive {:replicated,
                      {:sc_replication, Restdis.Cache, ^tenant_id, {:set_persist, ^key, false}}}
    end

    test "a nil transport disables replication", %{tenant_id: tenant_id} do
      TestUtils.put_transport(nil)
      key = Key.build(:table, "widgets", %{})

      assert :ok = Restdis.Cache.put(tenant_id, key, "v", persist: true)

      refute_receive {:replicated, _}, 100
    end

    test "RecordingTransport is a no-op when nothing is capturing", %{tenant_id: tenant_id} do
      TestUtils.stop_capturing_replication()
      key = Key.build(:table, "widgets", %{})

      assert :ok = Restdis.Cache.put(tenant_id, key, "v", persist: true)

      refute_receive {:replicated, _}, 100
    end
  end

  describe "apply_replicated on the receiving node" do
    test "put stores the entry as persist and counts it", %{tenant_id: tenant_id} do
      key = Key.build(:table, "widgets", %{})
      value = %{"id" => 3}

      assert :ok =
               Replication.apply_event(
                 Restdis.Cache,
                 tenant_id,
                 {:put, key, value, persist: true}
               )

      assert {:ok, ^value} = Restdis.Cache.peek(tenant_id, key)
      assert 1 = Restdis.Cache.persist_count(tenant_id)
    end

    test "put does not re-broadcast", %{tenant_id: tenant_id} do
      key = Key.build(:table, "widgets", %{})

      assert :ok =
               Replication.apply_event(Restdis.Cache, tenant_id, {:put, key, "v", persist: true})

      refute_receive {:replicated, _}, 100
    end

    test "put rebuilds the reverse index so WAL invalidation still applies", %{
      tenant_id: tenant_id
    } do
      key = Key.build(:table, "widgets", %{})
      value = [%{"id" => 42}]

      assert :ok =
               Replication.apply_event(
                 Restdis.Cache,
                 tenant_id,
                 {:put, key, value, persist: true}
               )

      assert :ok = Restdis.Cache.invalidate_by_row(tenant_id, "widgets", 42)
      Process.sleep(50)

      assert :miss = Restdis.Cache.peek(tenant_id, key)
    end

    test "put beyond the local persist cap is rejected", %{tenant_id: tenant_id} do
      key1 = Key.build(:table, "t", %{"a" => "1"})
      key2 = Key.build(:table, "t", %{"a" => "2"})

      assert :ok =
               Replication.apply_event(
                 Restdis.Cache,
                 tenant_id,
                 {:put, key1, "v1", persist: true, persist_cap: 1}
               )

      assert {:error, :persist_cap} =
               Replication.apply_event(
                 Restdis.Cache,
                 tenant_id,
                 {:put, key2, "v2", persist: true, persist_cap: 1}
               )
    end

    test "delete removes the local entry without re-broadcasting", %{tenant_id: tenant_id} do
      key = Key.build(:table, "widgets", %{})

      assert :ok =
               Replication.apply_event(Restdis.Cache, tenant_id, {:put, key, "v", persist: true})

      assert :ok = Replication.apply_event(Restdis.Cache, tenant_id, {:delete, key})
      Process.sleep(50)

      assert :miss = Restdis.Cache.peek(tenant_id, key)
      assert 0 = Restdis.Cache.persist_count(tenant_id)
      refute_receive {:replicated, _}, 100
    end

    test "set_persist false clears the local persist flag", %{tenant_id: tenant_id} do
      key = Key.build(:table, "widgets", %{})

      assert :ok =
               Replication.apply_event(Restdis.Cache, tenant_id, {:put, key, "v", persist: true})

      assert 1 = Restdis.Cache.persist_count(tenant_id)

      assert :ok = Replication.apply_event(Restdis.Cache, tenant_id, {:set_persist, key, false})

      assert 0 = Restdis.Cache.persist_count(tenant_id)
      refute_receive {:replicated, _}, 100
    end

    test "set_persist for an unknown key is a no-op", %{tenant_id: tenant_id} do
      key = Key.build(:table, "ghost", %{})

      assert {:error, :not_found} =
               Replication.apply_event(Restdis.Cache, tenant_id, {:set_persist, key, false})
    end
  end

  describe "receiver process" do
    test "applies an inbound replication message", %{tenant_id: tenant_id} do
      key = Key.build(:table, "widgets", %{})
      value = %{"id" => 9}

      GenServer.cast(
        Replication.Receiver.process_name(Restdis.Cache),
        {:sc_replication, Restdis.Cache, tenant_id, {:put, key, value, persist: true}}
      )

      :ok = GenServer.call(Replication.Receiver.process_name(Restdis.Cache), :sync)

      assert {:ok, ^value} = Restdis.Cache.peek(tenant_id, key)
    end

    test "ignores an unrecognized cast message" do
      GenServer.cast(Replication.Receiver.process_name(Restdis.Cache), :some_unknown_message)
      assert :ok = GenServer.call(Replication.Receiver.process_name(Restdis.Cache), :sync)
    end
  end

  describe "distribution transport" do
    test "broadcasting with no connected peers succeeds" do
      assert :ok =
               Distribution.broadcast(
                 Replication.Receiver.process_name(Restdis.Cache),
                 {:sc_replication, Restdis.Cache, "t", {:delete, Key.build(:table, "x", %{})}}
               )
    end
  end
end
