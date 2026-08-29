defmodule RestdisBuster.CacheHandler do
  @moduledoc """
  Default `Restdis.Wal.Handler` implementation, invalidating `Restdis.Cache`.

  This is the concrete wiring the application injects into
  `RestdisBuster.Worker`; the library-level dispatch logic knows nothing
  about `Restdis.Cache` directly.
  """

  @behaviour Restdis.Wal.Handler

  @impl Restdis.Wal.Handler
  def invalidate_by_row(tenant_id, table, pk) do
    Restdis.Cache.invalidate_by_row(tenant_id, table, pk)
  end

  @impl Restdis.Wal.Handler
  def flush_table(tenant_id, table) do
    Restdis.Cache.flush_table(tenant_id, table)
  end
end
