defmodule Restdis.Cache.ClusterTest do
  use ExUnit.Case, async: false

  alias Restdis.Cache.Cluster
  alias Restdis.Cache.Cluster.HashRing
  alias Restdis.Cache.TestUtils

  @ghost :"ghost@127.0.0.1"

  setup do
    on_exit(fn -> TestUtils.remove_cluster_node(@ghost) end)
    :ok
  end

  test "the local node owns every tenant while it is alone in the ring" do
    assert HashRing.nodes(Cluster.ring()) == [Node.self()]
    assert Cluster.owner("tenant_a") == Node.self()
    assert Cluster.local?("tenant_a")
  end

  test "a node join adds the node to the ring and moves part of the keyspace" do
    TestUtils.add_cluster_node(@ghost)

    assert @ghost in HashRing.nodes(Cluster.ring())

    remote =
      Enum.filter(1..200, fn index -> Cluster.owner("tenant_#{index}") == @ghost end)

    assert remote != []
    refute Cluster.local?(hd(remote) |> then(&"tenant_#{&1}"))
  end

  test "a node departure returns its tenants to the surviving node" do
    TestUtils.add_cluster_node(@ghost)
    tenant = TestUtils.tenant_owned_by(@ghost)
    assert Cluster.owner(tenant) == @ghost

    TestUtils.remove_cluster_node(@ghost)

    assert Cluster.owner(tenant) == Node.self()
    assert HashRing.nodes(Cluster.ring()) == [Node.self()]
  end

  test "membership changes emit a rebalance event" do
    handler = {__MODULE__, self()}

    :telemetry.attach(
      handler,
      [:restdis, :cluster, :rebalance],
      fn _event, measurements, metadata, pid ->
        send(pid, {:rebalance, measurements, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    TestUtils.add_cluster_node(@ghost)

    assert_receive {:rebalance, %{nodes: 2}, %{change: :join, node: @ghost}}
  end

  test "ignores an unrecognized info message" do
    send(Restdis.Cache.Cluster, :some_unknown_message)
    assert :ok = GenServer.call(Restdis.Cache.Cluster, :sync)
  end
end
