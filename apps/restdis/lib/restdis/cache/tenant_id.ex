defmodule Restdis.Cache.TenantId do
  @moduledoc """
  Validation and normalisation of tenant identifiers.
  """

  @pattern ~r/\A[A-Za-z0-9_-]{1,64}\z/

  @doc """
  Returns true when `id` is a well-formed tenant id.
  """
  @spec valid?(String.t()) :: boolean()
  def valid?(id), do: is_binary(id) and Regex.match?(@pattern, id)

  @doc """
  Returns `id`, raising `ArgumentError` when it is not a well-formed tenant id.
  """
  @spec cast!(String.t()) :: String.t()
  def cast!(id) do
    if valid?(id), do: id, else: raise(ArgumentError, "invalid tenant_id: #{inspect(id)}")
  end
end
