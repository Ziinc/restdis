defmodule Restdis.Cache.Origin.PostgREST do
  @moduledoc """
  Origin implementation that fetches values from PostgREST.

  `fetch/2` is only called by the three-layer read path when a client issues a
  bare GET on a cache key that has expired. The `Restdis.Cache.Key` struct
  carries only the `params_hash`, not the original params map, so PostgREST
  cannot reconstruct the query. Phase 2 returns `:error` here; the server's
  `PGRST.QUERY` command handler performs the fetch-and-cache cycle using the
  full path string available at command parse time.
  """

  @behaviour Restdis.Cache.Origin

  alias Restdis.Cache.Key

  @impl Restdis.Cache.Origin
  def fetch(_tenant_id, %Key{}), do: :error
end
