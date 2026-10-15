defmodule Restdis.Cache.Gossip.Tombstones do
  @moduledoc """
  Short-lived per-instance markers for read-through entries deleted on this
  node.

  An entry deleted here may still be in flight as gossip from a peer that
  loaded it before the delete. While its tombstone lives, inbound gossip for
  that `ident` is dropped as likely stale.
  """

  alias Restdis.Cache.Key
  alias Restdis.Cache.QueryCache
  alias Restdis.Cache.ReadThrough

  @doc """
  Returns the child spec of the tombstone store of the read-through instance `name`.
  """
  @spec child_spec(ReadThrough.name()) :: Supervisor.child_spec()
  def child_spec(name), do: QueryCache.child_spec(name, namespace(name))

  @doc """
  Marks `ident` as recently deleted for `ttl_ms`.
  """
  @spec put(ReadThrough.name(), ReadThrough.ident(), pos_integer()) :: :ok
  def put(name, ident, ttl_ms) do
    QueryCache.put(namespace(name), key(ident), true, name: name, ttl_ms: ttl_ms)
  end

  @doc """
  Returns whether `ident` carries a live tombstone.
  """
  @spec tombstoned?(ReadThrough.name(), ReadThrough.ident()) :: boolean()
  def tombstoned?(name, ident) do
    QueryCache.get(name, namespace(name), key(ident)) != :miss
  end

  defp namespace(name), do: ReadThrough.namespace(name) <> "/tombstones"

  defp key(ident), do: Key.build(:table, ident, %{})
end
