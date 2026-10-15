defmodule Restdis.Cache.Gossip do
  @moduledoc """
  Propagates read-through entries across the cluster.

  When a `Restdis.Cache.ReadThrough` instance started with `gossip:` loads an
  entry on a miss, it multicasts the value to a random subset of peers (a
  `ratio` of them, capped at `max_nodes`). A peer that receives it:

    * keeps its own value and refreshes its TTL if it already holds the entry;
    * drops it if the entry was deleted there within `tombstone_ttl_ms`, since
      the gossip may predate that delete;
    * caches it otherwise.

  A received entry is never re-multicast, which bounds propagation of any one
  load to a single hop. `nil` and `[]` are never gossiped, so a delayed
  negative lookup cannot shadow a record created in the meantime.

  Emits `[:restdis, :gossip, :multicast | :receive]` telemetry spans whose
  stop metadata carries the `:action` taken.
  """

  alias Restdis.Cache.Gossip.Tombstones
  alias Restdis.Cache.Gossip.Transport.Distribution
  alias Restdis.Cache.ReadThrough

  @defaults %{ratio: 0.05, max_nodes: 3, transport: Distribution, tombstone_ttl_ms: 60_000}

  @type config :: %{
          ratio: float(),
          max_nodes: pos_integer(),
          transport: module(),
          tombstone_ttl_ms: pos_integer()
        }
  @type multicast_action :: :done | :disabled | :ignore
  @type receive_action :: :cached | :refreshed | :dropped_stale | :dropped_not_started | :disabled

  @doc """
  Builds the gossip config from a `ReadThrough` `gossip:` option, `nil` when
  gossip is off.
  """
  @spec config(boolean() | keyword() | nil) :: config() | nil
  def config(opt) when opt in [nil, false], do: nil
  def config(true), do: @defaults
  def config(opts) when is_list(opts), do: Map.merge(@defaults, Map.new(opts))

  @doc """
  Picks `ceil(length(peers) * ratio)` random peers, at most `max_nodes`.
  """
  @spec select_peers([node()], float(), pos_integer()) :: [node()]
  def select_peers([], _ratio, _max_nodes), do: []

  def select_peers(peers, ratio, max_nodes) do
    Enum.take_random(peers, min(ceil(length(peers) * ratio), max_nodes))
  end

  @doc """
  Multicasts a freshly loaded `value` of `ident` to a subset of peers.
  """
  @spec multicast(ReadThrough.name(), ReadThrough.ident(), term()) :: multicast_action()
  def multicast(name, ident, value) do
    span(:multicast, name, ident, fn -> do_multicast(name, ident, value) end)
  end

  @doc false
  @spec receive(ReadThrough.name(), ReadThrough.ident(), term()) :: receive_action()
  def receive(name, ident, value) do
    span(:receive, name, ident, fn -> do_receive(name, ident, value) end)
  end

  @doc false
  @spec record_tombstone(ReadThrough.name(), ReadThrough.ident()) :: :ok
  def record_tombstone(name, ident) do
    case ReadThrough.gossip_config(name) do
      {:ok, %{tombstone_ttl_ms: ttl_ms}} -> Tombstones.put(name, ident, ttl_ms)
      _ -> :ok
    end
  end

  defp do_multicast(_name, _ident, nil), do: :ignore
  defp do_multicast(_name, _ident, []), do: :ignore

  defp do_multicast(name, ident, value) do
    case ReadThrough.gossip_config(name) do
      {:ok, %{transport: transport, ratio: ratio, max_nodes: max_nodes}} ->
        peers = select_peers(transport.peers(), ratio, max_nodes)
        if peers != [], do: transport.multicast(peers, name, ident, value)
        :done

      _ ->
        :disabled
    end
  end

  defp do_receive(name, ident, value) do
    case ReadThrough.gossip_config(name) do
      :not_started -> :dropped_not_started
      {:ok, nil} -> :disabled
      {:ok, _config} -> apply_received(name, ident, value)
    end
  end

  defp apply_received(name, ident, value) do
    case ReadThrough.fetch(name, ident, fn -> :miss end) do
      {:ok, local} ->
        ReadThrough.put(name, ident, local)
        :refreshed

      :miss ->
        if Tombstones.tombstoned?(name, ident) do
          :dropped_stale
        else
          ReadThrough.put(name, ident, value)
          :cached
        end
    end
  end

  defp span(event, name, ident, fun) do
    meta = %{name: name, ident: ident}

    :telemetry.span([:restdis, :gossip, event], meta, fn ->
      action = fun.()
      {action, Map.put(meta, :action, action)}
    end)
  end
end
