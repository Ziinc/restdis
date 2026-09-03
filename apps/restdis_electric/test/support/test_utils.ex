defmodule RestdisElectric.TestUtils do
  @moduledoc """
  Shared test helpers for the `restdis_electric` bounded context.
  """

  @spec tenant_id() :: String.t()
  def tenant_id, do: "tenant_#{System.unique_integer([:positive])}"

  @spec put_table(String.t(), map()) :: :ok
  def put_table(qualified_name, info) do
    tables = Application.get_env(:restdis_electric, :tables, %{})
    Application.put_env(:restdis_electric, :tables, Map.put(tables, qualified_name, info))
  end

  @spec put_stub_rows(String.t(), [map()]) :: :ok
  def put_stub_rows(table, rows) do
    stub_rows = Application.get_env(:restdis_electric, :stub_rows, %{})
    Application.put_env(:restdis_electric, :stub_rows, Map.put(stub_rows, table, rows))
  end
end
