defmodule Restdis.Wal.Handler do
  @moduledoc """
  Behaviour a host implements to react to decoded WAL events.

  A WAL follower (slated to move into this library as `Restdis.Wal` per
  LIB_PRD Phase 4) decodes row-level changes and dispatches them to a handler
  configured by the host, rather than calling a concrete cache module
  directly. This is what lets the follower run without any cache tree
  started at all, and lets two hosts apply WAL events differently.
  """

  @typedoc "A tenant identifier, opaque to the WAL follower."
  @type tenant_id :: String.t()

  @doc """
  Invalidates every cache entry that depends on the row `{table, pk}`.
  """
  @callback invalidate_by_row(tenant_id(), table :: String.t(), pk :: term()) :: :ok

  @doc """
  Invalidates every cache entry that depends on `table`.
  """
  @callback flush_table(tenant_id(), table :: String.t()) :: :ok
end
