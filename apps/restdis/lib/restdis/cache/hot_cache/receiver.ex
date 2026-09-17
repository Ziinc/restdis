defmodule Restdis.Cache.HotCache.Receiver do
  @moduledoc """
  Node-local endpoint for inbound hot-cache gossip messages.

  Every message applied here stops: this node never re-broadcasts what it
  receives, which bounds a single promotion or delete to one gossip hop.
  """

  use GenServer

  alias Restdis.Cache.HotCache

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    {:ok, %{}}
  end

  @impl GenServer
  def handle_cast({:sc_hot_cache_put, tenant_id, key, value, ttl_ms}, state) do
    HotCache.apply_gossip_put(tenant_id, key, value, ttl_ms)
    {:noreply, state}
  end

  def handle_cast({:sc_hot_cache_delete, tenant_id, key}, state) do
    HotCache.apply_gossip_delete(tenant_id, key)
    {:noreply, state}
  end

  def handle_cast(_message, state), do: {:noreply, state}

  @impl GenServer
  def handle_call(:sync, _from, state), do: {:reply, :ok, state}
end
