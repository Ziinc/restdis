defmodule SupaCacherCache.Origin.Stub do
  @behaviour SupaCacherCache.Origin

  @impl SupaCacherCache.Origin
  def fetch(_tenant_id, _key), do: :error
end
