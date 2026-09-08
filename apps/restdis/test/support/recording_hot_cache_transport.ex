defmodule Restdis.Cache.TestUtils.RecordingHotCacheTransport do
  @moduledoc """
  Hot-cache transport that forwards every gossip message to the capturing
  test process instead of the network.
  """

  @behaviour Restdis.Cache.HotCache.Transport

  alias Restdis.Cache.TestUtils

  @impl Restdis.Cache.HotCache.Transport
  def broadcast(message) do
    case TestUtils.hot_cache_target() do
      nil -> :ok
      pid -> send(pid, {:gossiped, message})
    end

    :ok
  end
end
