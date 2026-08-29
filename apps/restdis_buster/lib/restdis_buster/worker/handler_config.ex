defmodule RestdisBuster.Worker.HandlerConfig do
  @moduledoc """
  Resolves the configured `Restdis.Wal.Handler` implementation.

  Shared by `RestdisBuster.Worker` and `RestdisBuster.Worker.CoalesceSweeper`
  so both the per-row/DDL/truncate invalidation path and the backpressure
  fallback flush path dispatch through the same injected handler, keeping
  the WAL follower decoupled from `Restdis.Cache` (LIB_PRD Phase 4/5).
  """

  @doc """
  Returns the module implementing `Restdis.Wal.Handler` configured via
  `:restdis_buster, :wal_handler`, defaulting to `RestdisBuster.CacheHandler`.
  """
  @spec handler() :: module()
  def handler do
    Application.get_env(:restdis_buster, :wal_handler, RestdisBuster.CacheHandler)
  end
end
