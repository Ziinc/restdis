defmodule Restdis.Cache.Origin.PostgREST do
  @moduledoc """
  Origin implementation that fetches values from PostgREST.

  `fetch/2` is only called by the three-layer read path when a client issues a
  bare GET on a cache key that has expired. That path only has the
  `Restdis.Cache.Key` struct to go on, not the tenant id or the raw request
  path, so it cannot look up the original query string a key was parsed from,
  nor resolve which tenant's PostgREST to call. Phase 2 returns `:error`
  here; the host application's query command handler performs the
  fetch-and-cache cycle using the full path string and tenant id available
  at command parse time, via its own PostgREST fetcher implementation.
  """

  @behaviour Restdis.Cache.Origin

  alias Restdis.Cache.Key

  @impl Restdis.Cache.Origin
  def fetch(_tenant_id, %Key{}), do: :error
end
