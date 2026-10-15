defmodule Restdis.Cache.Gossip.Transport.Distribution do
  @moduledoc """
  Multicasts gossip over Erlang distribution to `Restdis.Cache.Gossip.receive/3`
  on each selected peer.

  Delivery is asynchronous and best-effort: a peer that misses a multicast
  simply loads the entry itself on its next miss.
  """

  @behaviour Restdis.Cache.Gossip.Transport

  alias Restdis.Cache.Gossip

  @impl Restdis.Cache.Gossip.Transport
  def peers, do: Node.list()

  @impl Restdis.Cache.Gossip.Transport
  def multicast(peers, name, ident, value) do
    :erpc.multicast(peers, Gossip, :receive, [name, ident, value])
  end
end
