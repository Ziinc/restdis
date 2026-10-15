defmodule Restdis.Cache.TestUtils.RecordingGossipTransport do
  @moduledoc """
  Gossip transport that reports three fake peers and forwards every multicast
  to the capturing test process instead of the network.
  """

  @behaviour Restdis.Cache.Gossip.Transport

  alias Restdis.Cache.TestUtils

  @impl Restdis.Cache.Gossip.Transport
  def peers, do: [:peer_a@nohost, :peer_b@nohost, :peer_c@nohost]

  @impl Restdis.Cache.Gossip.Transport
  def multicast(peers, name, ident, value) do
    case TestUtils.gossip_target() do
      nil -> :ok
      pid -> send(pid, {:gossip_multicast, peers, name, ident, value})
    end

    :ok
  end
end
