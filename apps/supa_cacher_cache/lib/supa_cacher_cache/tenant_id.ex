defmodule SupaCacherCache.TenantId do
  @moduledoc """
  Validation and normalisation of tenant identifiers.
  """

  @pattern ~r/\A[A-Za-z0-9_-]{1,64}\z/

  @spec valid?(String.t()) :: boolean()
  def valid?(id), do: is_binary(id) and Regex.match?(@pattern, id)

  @spec cast!(String.t()) :: String.t()
  def cast!(id) do
    if valid?(id), do: id, else: raise(ArgumentError, "invalid tenant_id: #{inspect(id)}")
  end
end
