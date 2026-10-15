defmodule Restdis.Cache.GossipTest do
  use ExUnit.Case, async: false

  alias Restdis.Cache.Gossip
  alias Restdis.Cache.Gossip.Transport.Distribution
  alias Restdis.Cache.ReadThrough
  alias Restdis.Cache.TestUtils
  alias Restdis.Cache.TestUtils.RecordingGossipTransport

  setup context do
    TestUtils.capture_gossip(self())
    on_exit(&TestUtils.stop_capturing_gossip/0)

    name = :"gossip_#{System.unique_integer([:positive])}"
    data_dir = Path.join(System.tmp_dir!(), "restdis_gossip_#{name}")
    on_exit(fn -> File.rm_rf!(data_dir) end)

    gossip =
      Map.get(context, :gossip,
        ratio: 1.0,
        max_nodes: 2,
        transport: RecordingGossipTransport
      )

    start_supervised!({ReadThrough, name: name, data_dir: data_dir, gossip: gossip})

    %{name: name}
  end

  describe "select_peers/3" do
    test "selects nothing when there are no peers" do
      assert [] = Gossip.select_peers([], 1.0, 3)
    end

    test "selects the ratio of peers rounded up, capped at max_nodes" do
      peers = Enum.map(1..10, &:"n#{&1}@host")

      assert [_] = Gossip.select_peers(peers, 0.05, 3)
      assert [_, _, _] = Gossip.select_peers(peers, 0.25, 5)
      assert [_, _, _, _] = selected = Gossip.select_peers(peers, 1.0, 4)
      assert Enum.all?(selected, &(&1 in peers))
    end
  end

  describe "multicast from ReadThrough.fetch/3" do
    test "a loaded value is multicast to the selected peers", %{name: name} do
      assert {:ok, 1} = ReadThrough.fetch(name, "k", fn -> {:ok, 1} end)

      assert_receive {:gossip_multicast, [_, _], ^name, "k", 1}
    end

    test "a cache hit is not multicast", %{name: name} do
      assert {:ok, 1} = ReadThrough.fetch(name, "k", fn -> {:ok, 1} end)
      assert_receive {:gossip_multicast, _, _, _, _}

      assert {:ok, 1} = ReadThrough.fetch(name, "k", fn -> flunk("loader ran") end)
      refute_receive {:gossip_multicast, _, _, _, _}, 50
    end

    test "nil and empty list values are not multicast", %{name: name} do
      assert {:ok, nil} = ReadThrough.fetch(name, "nil", fn -> {:ok, nil} end)
      assert {:ok, []} = ReadThrough.fetch(name, "empty", fn -> {:ok, []} end)

      refute_receive {:gossip_multicast, _, _, _, _}, 50
    end

    test "a loader miss is not multicast", %{name: name} do
      assert :miss = ReadThrough.fetch(name, "k", fn -> :miss end)

      refute_receive {:gossip_multicast, _, _, _, _}, 50
    end

    @tag gossip: false
    test "an instance without gossip does not multicast", %{name: name} do
      assert {:ok, 1} = ReadThrough.fetch(name, "k", fn -> {:ok, 1} end)

      refute_receive {:gossip_multicast, _, _, _, _}, 50
    end
  end

  describe "receive/3" do
    test "caches a value this node does not hold", %{name: name} do
      assert :cached = Gossip.receive(name, "k", 1)

      assert {:ok, 1} = ReadThrough.fetch(name, "k", fn -> flunk("loader ran") end)
    end

    test "keeps the local value of a key this node already holds", %{name: name} do
      assert :ok = ReadThrough.put(name, "k", :local)

      assert :refreshed = Gossip.receive(name, "k", :remote)

      assert {:ok, :local} = ReadThrough.fetch(name, "k", fn -> flunk("loader ran") end)
    end

    test "drops a value for a key deleted on this node", %{name: name} do
      assert :ok = ReadThrough.delete(name, "k")

      assert :dropped_stale = Gossip.receive(name, "k", :stale)

      assert {:ok, :fresh} = ReadThrough.fetch(name, "k", fn -> {:ok, :fresh} end)
    end

    @tag gossip: [transport: RecordingGossipTransport, tombstone_ttl_ms: 1]
    test "caches a value once the key's tombstone has expired", %{name: name} do
      assert :ok = ReadThrough.delete(name, "k")
      Process.sleep(5)

      assert :cached = Gossip.receive(name, "k", 1)
    end

    test "drops a value for an instance not started on this node" do
      assert :dropped_not_started = Gossip.receive(:gossip_never_started, "k", 1)
    end

    @tag gossip: false
    test "drops a value for an instance without gossip", %{name: name} do
      assert :disabled = Gossip.receive(name, "k", 1)

      assert {:ok, 2} = ReadThrough.fetch(name, "k", fn -> {:ok, 2} end)
    end

    test "emits a receive telemetry span carrying the action", %{name: name} do
      ref = :telemetry_test.attach_event_handlers(self(), [[:restdis, :gossip, :receive, :stop]])

      Gossip.receive(name, "k", 1)

      assert_receive {[:restdis, :gossip, :receive, :stop], ^ref, %{duration: _},
                      %{name: ^name, ident: "k", action: :cached}}
    end
  end

  describe "distribution transport" do
    test "lists connected nodes as peers" do
      assert Distribution.peers() == Node.list()
    end

    test "multicasting to no peers succeeds" do
      assert :ok = Distribution.multicast([], :any, "k", 1)
    end
  end
end
