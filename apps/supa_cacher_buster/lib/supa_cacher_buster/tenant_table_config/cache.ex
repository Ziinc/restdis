defmodule SupaCacherBuster.TenantTableConfig.Cache do
  use GenServer

  import Ecto.Query

  alias SupaCacherRepo.TenantTableConfig, as: Schema

  @table :supa_cacher_buster_table_config

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec lookup(String.t(), String.t()) :: {:ok, map()} | :not_found
  def lookup(schema, table_name) do
    case :ets.lookup(@table, {schema, table_name}) do
      [{_, config}] ->
        {:ok, config}

      [] ->
        case fetch_from_db(schema, table_name) do
          {:ok, config} ->
            :ets.insert(@table, {{schema, table_name}, config})
            {:ok, config}

          :not_found ->
            :not_found
        end
    end
  end

  @spec invalidate(String.t(), String.t()) :: :ok
  def invalidate(schema, table_name) do
    :ets.delete(@table, {schema, table_name})
    :ok
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  defp fetch_from_db(schema, table_name) do
    case SupaCacherRepo.one(
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
