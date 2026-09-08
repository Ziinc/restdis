defmodule Restdis.Cache.HotCache.Transport do
  @moduledoc """
  Transport used to gossip hot-cache promotions and deletes to peer nodes.
  """

  @callback broadcast(Restdis.Cache.HotCache.gossip_message()) :: :ok
end
