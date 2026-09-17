defmodule Restdis.Cache.HotCache.Transport.Distribution do
  @moduledoc """
  Gossips hot-cache messages to every connected peer over Erlang distribution.

  Delivery is asynchronous and best-effort: a peer that misses a promotion
  simply keeps routing that key to the tenant owner until it turns hot
  locally too.
  """

  @behaviour Restdis.Cache.HotCache.Transport

  alias Restdis.Cache.HotCache.Receiver

  @impl Restdis.Cache.HotCache.Transport
  def broadcast(message) do
    GenServer.abcast(Node.list(), Receiver, message)
    :ok
  end
end
