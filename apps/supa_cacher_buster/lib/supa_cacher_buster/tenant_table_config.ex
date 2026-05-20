defmodule SupaCacherBuster.TenantTableConfig do
  @moduledoc false

  alias SupaCacherBuster.TenantTableConfig.Cache

  @type config :: %{
          tenant_id: String.t(),
          schema: String.t(),
          table_name: String.t(),
          mode: String.t(),
          pk_column: String.t()
        }

  @spec lookup(String.t(), String.t()) :: {:ok, config()} | :not_found
  def lookup(schema, table_name), do: Cache.lookup(schema, table_name)

  @spec invalidate(String.t(), String.t()) :: :ok
  def invalidate(schema, table_name), do: Cache.invalidate(schema, table_name)
end
