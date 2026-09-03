defmodule RestdisElectric.TableInfo do
  @moduledoc """
  Behaviour and dispatch for reading a table's schema.

  A shape is only valid if its table exists, its column list covers the primary
  key, and — once live updates are on — the table replicates its complete old
  row. The implementation is chosen by the `:table_info` application
  environment key so the context's own tests need no database.
  """

  @type info :: %{
          columns: [String.t()],
          primary_key: [String.t()],
          replica_identity: :default | :full | :nothing | :index,
          types: %{String.t() => String.t()}
        }

  @callback fetch(schema :: String.t(), table :: String.t()) :: {:ok, info()} | :error

  @doc """
  Reads the schema of `schema`.`table` through the configured implementation.
  """
  @spec fetch(String.t(), String.t()) :: {:ok, info()} | :error
  def fetch(schema, table), do: impl().fetch(schema, table)

  @doc """
  Returns the configured implementation module.
  """
  @spec impl() :: module()
  def impl do
    Application.get_env(:restdis_electric, :table_info, RestdisElectric.TableInfo.Static)
  end
end
