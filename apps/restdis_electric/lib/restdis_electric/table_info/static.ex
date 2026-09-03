defmodule RestdisElectric.TableInfo.Static do
  @moduledoc """
  Table schemas taken from application configuration.

  Configure `:restdis_electric, :tables` as a map of `"schema.table"` to an
  info map. Used in tests and local runs, where no Postgres is available.
  """

  @behaviour RestdisElectric.TableInfo

  @impl RestdisElectric.TableInfo
  def fetch(schema, table) do
    case Map.fetch(tables(), "#{schema}.#{table}") do
      {:ok, info} -> {:ok, normalize(info)}
      :error -> :error
    end
  end

  defp tables, do: Application.get_env(:restdis_electric, :tables, %{})

  defp normalize(info) do
    %{
      columns: Map.get(info, :columns, []),
      primary_key: Map.get(info, :primary_key, []),
      replica_identity: Map.get(info, :replica_identity, :default),
      types: Map.get(info, :types, %{})
    }
  end
end
