defmodule RestdisElectric.WAL do
  @moduledoc """
  Entry point for decoded WAL changes pushed from the WAL reader.

  This module receives plain maps, not the WAL reader's own event struct:
  this context must not reference the WAL reader's namespace, so the
  dependency points from the WAL reader into this context, and the reader is
  responsible for translating its own event struct before calling here.

  `ingest/1` returns only after every matching shape has durably appended
  the change (`RestdisElectric.Log.append/3` persists synchronously), so a
  caller can safely confirm the change's LSN to Postgres once every
  `ingest/1` call up to that LSN has returned.
  """

  alias RestdisElectric.Log
  alias RestdisElectric.Message
  alias RestdisElectric.ShapeRegistry

  @type change :: %{
          required(:tenant_id) => String.t() | nil,
          required(:schema) => String.t(),
          required(:table) => String.t(),
          required(:op) => :insert | :update | :delete,
          required(:pk) => term(),
          required(:lsn) => non_neg_integer() | nil,
          optional(:new_row) => map() | nil,
          optional(:old_row) => map() | nil
        }

  @doc """
  Applies a decoded change to every shape currently reading its table.
  """
  @spec ingest(change()) :: :ok
  def ingest(%{tenant_id: nil}), do: :ok
  def ingest(%{lsn: nil}), do: :ok

  def ingest(%{tenant_id: tenant_id, schema: schema, table: table, op: op, pk: pk, lsn: lsn} = c)
      when is_binary(tenant_id) and is_integer(lsn) and op in [:insert, :update, :delete] do
    case ShapeRegistry.handles_for(tenant_id, schema, table) do
      [] ->
        :ok

      handles ->
        offset = {lsn, :erlang.unique_integer([:monotonic, :positive])}
        message = Message.change(offset, op, to_string(pk), Map.get(c, :new_row))
        Enum.each(handles, &Log.append(tenant_id, &1, [message]))
        :ok
    end
  end

  def ingest(_change), do: :ok
end
