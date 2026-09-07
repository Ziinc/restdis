defmodule Restdis.Migrations.SqlQuoting do
  @moduledoc false

  @doc false
  @spec quote_ident(String.t()) :: String.t()
  def quote_ident(ident), do: ~s("#{String.replace(ident, "\"", "\"\"")}")

  @doc false
  @spec quote_literal(String.t()) :: String.t()
  def quote_literal(value), do: "'#{String.replace(value, "'", "''")}'"
end
