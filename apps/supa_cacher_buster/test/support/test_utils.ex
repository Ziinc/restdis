defmodule SupaCacherBuster.TestUtils do
  @moduledoc false

  alias SupaCacherBuster.WAL.Event

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
