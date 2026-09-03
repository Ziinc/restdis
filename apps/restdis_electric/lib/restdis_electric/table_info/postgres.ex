defmodule RestdisElectric.TableInfo.Postgres do
  @moduledoc """
  Table schemas read from the catalogue of a live Postgres.

  The repo module is taken from the `:repo` application environment key so this
  context does not name the host application's repo.
  """

  @behaviour RestdisElectric.TableInfo

  require Logger

  alias Ecto.Adapters.SQL

  @columns_query """
  SELECT a.attname, format_type(a.atttypid, a.atttypmod)
  FROM pg_attribute a
  JOIN pg_class c ON c.oid = a.attrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = $1 AND c.relname = $2 AND a.attnum > 0 AND NOT a.attisdropped
  ORDER BY a.attnum
  """

  @primary_key_query """
  SELECT a.attname
  FROM pg_index i
  JOIN pg_class c ON c.oid = i.indrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = ANY(i.indkey)
  WHERE n.nspname = $1 AND c.relname = $2 AND i.indisprimary
  """

  @replica_identity_query """
  SELECT c.relreplident
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = $1 AND c.relname = $2
  """

  @impl RestdisElectric.TableInfo
  def fetch(schema, table) do
    with {:ok, columns} <- query(@columns_query, [schema, table]),
         false <- columns == [],
         {:ok, pk_rows} <- query(@primary_key_query, [schema, table]),
         {:ok, ident_rows} <- query(@replica_identity_query, [schema, table]) do
      {:ok,
       %{
         columns: Enum.map(columns, fn [name, _type] -> name end),
         primary_key: Enum.map(pk_rows, fn [name] -> name end),
         replica_identity: replica_identity(ident_rows),
         types: Map.new(columns, fn [name, type] -> {name, type} end)
       }}
    else
      _ -> :error
    end
  end

  defp query(sql, args) do
    case SQL.query(repo(), sql, args) do
      {:ok, %{rows: rows}} -> {:ok, rows}
      {:error, _reason} -> :error
    end
  rescue
    error ->
      Logger.warning("TableInfo.Postgres: query failed: #{Exception.message(error)}")
      :error
  end

  defp replica_identity([["f"]]), do: :full
  defp replica_identity([["n"]]), do: :nothing
  defp replica_identity([["i"]]), do: :index
  defp replica_identity(_), do: :default

  defp repo, do: Application.fetch_env!(:restdis_electric, :repo)
end
