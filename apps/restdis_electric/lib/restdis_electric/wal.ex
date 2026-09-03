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

  ## Rows that enter and leave a shape

  A shape's filter is tested against both the pre-image and the post-image of
  a change, and the operation we log follows from the pair, not from the
  operation Postgres reported:

  | Before | After | Logged |
  | --- | --- | --- |
  | no match | match | `insert` — the client has never seen this row |
  | match | match | `update` |
  | match | no match | `delete` — the client must drop it, though the row still exists |
  | no match | no match | nothing |

  Without this, a client's copy silently keeps rows that have left its shape
  and never learns about rows that entered it. Testing the pre-image needs the
  complete previous row, which is why `RestdisElectric.Definition` requires
  `REPLICA IDENTITY FULL` on every table a shape reads.
  """

  alias RestdisElectric.Definition
  alias RestdisElectric.Eval
  alias RestdisElectric.Filter
  alias RestdisElectric.Log
  alias RestdisElectric.Message
  alias RestdisElectric.ShapeRegistry
  alias RestdisElectric.SubqueryTracker

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
  Applies a decoded change to every shape whose filter matches it, before or
  after the change.
  """
  @spec ingest(change()) :: :ok
  def ingest(%{tenant_id: nil}), do: :ok
  def ingest(%{lsn: nil}), do: :ok

  def ingest(%{tenant_id: tenant_id, schema: schema, table: table, op: op, pk: pk, lsn: lsn} = c)
      when is_binary(tenant_id) and is_integer(lsn) and op in [:insert, :update, :delete] do
    new_row = Map.get(c, :new_row)
    old_row = Map.get(c, :old_row)

    SubqueryTracker.route_inner_change(tenant_id, schema, table, %{
      new_row: new_row,
      old_row: old_row,
      lsn: lsn
    })

    case Filter.candidates(tenant_id, schema, table, [new_row, old_row]) do
      [] ->
        :ok

      handles ->
        start = System.monotonic_time()
        offset = {lsn, :erlang.unique_integer([:monotonic, :positive])}

        change = %{offset: offset, op: op, pk: pk, new_row: new_row, old_row: old_row}
        appended = Enum.count(handles, &apply_to_shape(&1, tenant_id, change, start))

        :telemetry.execute(
          [:restdis_electric, :wal, :ingest],
          %{
            duration: System.monotonic_time() - start,
            tested: length(handles),
            appended: appended
          },
          %{tenant_id: tenant_id, schema: schema, table: table, operation: op}
        )

        :ok
    end
  end

  def ingest(_change), do: :ok

  defp apply_to_shape(handle, tenant_id, change, ingest_started_at) do
    %{op: op, new_row: new_row, old_row: old_row} = change
    definition = definition_for(tenant_id, handle)
    filter = definition.filter
    resolver = SubqueryTracker.resolver(tenant_id, handle)

    matched_before = op != :insert and Eval.matches?(filter, old_row, resolver)
    matched_after = op != :delete and Eval.matches?(filter, new_row, resolver)

    case logged_operation(matched_before, matched_after) do
      nil ->
        false

      operation ->
        message = message(definition, operation, change)

        case Log.append(tenant_id, handle, [message]) do
          :ok ->
            emit_propagation_latency(tenant_id, ingest_started_at)
            true

          {:error, _reason} ->
            false
        end
    end
  end

  # A waiting long-poll/SSE loop wakes the instant this append returns, so this doubles as delivery delay.
  defp emit_propagation_latency(tenant_id, ingest_started_at) do
    duration_us =
      System.convert_time_unit(System.monotonic_time() - ingest_started_at, :native, :microsecond)

    :telemetry.execute(
      [:restdis_electric, :propagation, :latency],
      %{duration_us: duration_us},
      %{tenant_id: tenant_id}
    )
  end

  # A shape with no definition yet (or lost on restart) has no filter, so every change to its table logs.
  defp definition_for(tenant_id, handle) do
    case ShapeRegistry.fetch(tenant_id, handle) do
      {:ok, definition} -> definition
      :error -> %Definition{tenant_id: tenant_id, schema: "", table: ""}
    end
  end

  defp logged_operation(false, true), do: :insert
  defp logged_operation(true, true), do: :update
  defp logged_operation(true, false), do: :delete
  defp logged_operation(false, false), do: nil

  defp message(definition, operation, %{
         offset: offset,
         pk: pk,
         new_row: new_row,
         old_row: old_row
       }) do
    value = project(definition, row_for(operation, new_row, old_row))

    %Message{
      offset: offset,
      operation: operation,
      key: to_string(pk),
      value: value,
      old_value: old_value(definition, operation, old_row)
    }
  end

  # A row that left the shape is reported as a delete, and the only row we have for it is the pre-image.
  defp row_for(:delete, _new_row, old_row), do: old_row
  defp row_for(_operation, new_row, old_row), do: new_row || old_row

  defp old_value(%Definition{replica: :full} = definition, operation, old_row)
       when operation in [:update, :delete],
       do: project(definition, old_row)

  defp old_value(_definition, _operation, _old_row), do: nil

  defp project(_definition, nil), do: nil
  defp project(%Definition{columns: nil}, row), do: row
  defp project(%Definition{columns: columns}, row), do: Map.take(row, columns)
end
