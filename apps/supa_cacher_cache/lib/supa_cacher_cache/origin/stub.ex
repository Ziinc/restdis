defmodule SupaCacherCache.Origin.Stub do
  @moduledoc """
  Origin implementation returning canned values, used in tests and local runs.
  """

  @behaviour SupaCacherCache.Origin

  @impl SupaCacherCache.Origin
  def fetch(_tenant_id, _key), do: :error
end
