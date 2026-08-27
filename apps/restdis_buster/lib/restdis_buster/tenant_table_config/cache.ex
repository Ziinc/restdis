defmodule RestdisBuster.TenantTableConfig.Cache do
  @moduledoc """
  Per-tenant table configuration read through the multi-layer cache.

  The cache instance (`Restdis.Cache.ReadThrough`) is configured where it is
  supervised; this module only maps a lookup onto it.
  """

  import Ecto.Query

  alias Restdis.Cache.ReadThrough
  alias RestdisRepo.TenantTableConfig, as: Schema

  @cache_name :tenant_table_config

  @doc """
  Returns the name of the read-through cache instance holding table configs.
  """
  @spec cache_name() :: atom()
  def cache_name, do: @cache_name

  @doc """
  Returns the cached configuration, reading through to the database on a miss.
  """
  @spec lookup(String.t(), String.t()) :: {:ok, map()} | :not_found
  def lookup(schema, table_name) do
    ReadThrough.fetch(@cache_name, ident(schema, table_name), fn ->
      fetch_from_db(schema, table_name)
    end)
  end

  @doc """
  Removes the cached entry so the next lookup reads through to the database.
  """
  @spec invalidate(String.t(), String.t()) :: :ok
  def invalidate(schema, table_name) do
    ReadThrough.delete(@cache_name, ident(schema, table_name))
  end

  defp ident(schema, table_name), do: "tenant_table_config/#{schema}.#{table_name}"

  defp fetch_from_db(schema, table_name) do
    case RestdisRepo.one(
           from(ttc in Schema,
             where: ttc.schema == ^schema and ttc.table_name == ^table_name,
             limit: 1
           )
         ) do
      nil ->
        :not_found

      ttc ->
        config = %{
          tenant_id: ttc.tenant_id,
          schema: ttc.schema,
          table_name: ttc.table_name,
          mode: ttc.mode,
          pk_column: ttc.pk_column
        }

        {:ok, config}
    end
  end
end
