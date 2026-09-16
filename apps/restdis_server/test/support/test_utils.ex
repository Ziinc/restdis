defmodule RestdisServer.TestUtils do
  @moduledoc false

  @doc """
  Builds the handler state a command's `run/2` expects, for `tenant_id`.
  """
  @spec state(String.t()) :: map()
  def state(tenant_id), do: %{authenticated?: true, tenant_id: tenant_id, buffer: <<>>}
end
