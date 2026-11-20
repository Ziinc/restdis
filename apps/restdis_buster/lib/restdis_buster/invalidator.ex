defmodule RestdisBuster.Invalidator do
  @moduledoc """
  Behaviour `RestdisBuster.Worker` invalidates the cache through.

  `RestdisBuster.CacheHandler` implements it against `Restdis.Cache`; tests inject
  stubs via `:restdis_buster, :wal_handler` (see `RestdisBuster.Worker.HandlerConfig`).
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

  @doc """
  Invalidates every list-scoped cache entry for `table`.

  Called on row insert, since a newly inserted row's primary key was never
  indexed and so can't be purged via `invalidate_by_row/3`.
  """
  @callback invalidate_lists(tenant_id(), table :: String.t()) :: :ok
end
