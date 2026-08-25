defmodule Restdis.Cache.Origin.Stub do
  @moduledoc """
  Origin implementation returning canned values, used in tests and local runs.
  """

  @behaviour Restdis.Cache.Origin

  @impl Restdis.Cache.Origin
  def fetch(_tenant_id, _key), do: :error
end
