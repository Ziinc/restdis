defmodule SupaCacherBuster.TestUtils do
  @moduledoc false

  alias SupaCacherBuster.TenantTableConfig
  alias SupaCacherBuster.WAL.Event
  alias SupaCacherCache.ReadThrough

  @doc false
  @spec seed_table_config(String.t(), String.t(), map()) :: :ok
  def seed_table_config(schema, table, config) do
    ReadThrough.put(TenantTableConfig.Cache.cache_name(), {schema, table}, config)
  end

  @doc false
  @spec clear_table_config() :: :ok
  def clear_table_config do
    ReadThrough.flush(TenantTableConfig.Cache.cache_name())
  end

  @spec insert_event(String.t(), String.t(), map()) :: Event.t()
  def insert_event(table, schema \\ "public", row \\ %{}) do
    %Event{op: :insert, schema: schema, table: table, new_row: row}
  end

  @spec update_event(String.t(), String.t(), map(), map()) :: Event.t()
  def update_event(table, schema \\ "public", old_row \\ %{}, new_row \\ %{}) do
    %Event{op: :update, schema: schema, table: table, old_row: old_row, new_row: new_row}
  end

  @spec delete_event(String.t(), String.t(), map()) :: Event.t()
  def delete_event(table, schema \\ "public", old_row \\ %{}) do
    %Event{op: :delete, schema: schema, table: table, old_row: old_row}
  end

  @spec truncate_event(String.t(), String.t()) :: Event.t()
  def truncate_event(table, schema \\ "public") do
    %Event{op: :truncate, schema: schema, table: table}
  end
end
