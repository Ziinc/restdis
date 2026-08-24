defmodule SupaCacherCache.Origin do
  @moduledoc """
  Behaviour for fetching a cache key's value from its origin.
  """

  @callback fetch(tenant_id :: String.t(), SupaCacherCache.Key.t()) :: {:ok, term()} | :error
end
