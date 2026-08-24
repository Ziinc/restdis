defmodule SupaCacherBuster.WAL.Pgoutput do
  @moduledoc false

  alias SupaCacherBuster.WAL.Event
  alias SupaCacherBuster.WAL.RelationCache

  @type state :: {RelationCache.t(), non_neg_integer() | nil}

  @doc """
  Decode a single pgoutput frame.

  The second argument may be a bare `RelationCache` (legacy, no LSN tracking)
  or `{cache, current_txn_lsn}`. Returns events plus the new state in the same
  shape as the input.
  """
  @spec decode(binary(), RelationCache.t() | state()) ::
          {[Event.t()], RelationCache.t() | state()}

  def decode(frame, {_cache, _txn_lsn} = state) do
    {events, new_state} = do_decode(frame, state)
    {events, new_state}
  end

  def decode(frame, cache) do
    {events, {new_cache, _}} = do_decode(frame, {cache, nil})
    {events, new_cache}
  end

  # Begin: capture the transaction's final LSN so it can be stamped on
  # the row events that follow before the matching Commit frame.
  defp do_decode(<<?B, fin_lsn::64, _ts::64, _xid::32, _rest::binary>>, {cache, _}) do
    {[], {cache, fin_lsn}}
  end

  defp do_decode(<<?C, _flags::8, _commit_lsn::64, _end_lsn::64, _ts::64>>, {cache, _}) do
    {[], {cache, nil}}
  end

  defp do_decode(<<?R, oid::32, rest::binary>>, {cache, txn_lsn}) do
    {namespace, rest} = read_cstring(rest)
    {table_name, rest} = read_cstring(rest)
    <<_identity::8, num_cols::16, cols_bin::binary>> = rest
    {columns, _} = decode_columns(cols_bin, num_cols, [])
    new_cache = RelationCache.update(cache, oid, namespace, table_name, columns)
    {[], {new_cache, txn_lsn}}
  end

  defp do_decode(<<?I, oid::32, ?N, tuple::binary>>, {cache, txn_lsn} = state) do
    case RelationCache.lookup(cache, oid) do
      {:ok, rel} ->
        {row, _} = decode_tuple(tuple, rel.columns)

        event = %Event{
          schema: rel.schema,
          table: rel.table,
          op: :insert,
          new_row: row,
          lsn: txn_lsn,
          received_at: System.monotonic_time(:microsecond)
        }

        {[event], state}

      :not_found ->
        {[], state}
    end
  end

  defp do_decode(<<?U, oid::32, rest::binary>>, {cache, txn_lsn} = state) do
    case RelationCache.lookup(cache, oid) do
      {:ok, rel} ->
        {old_row, new_row, _} = decode_update_tuples(rest, rel.columns)

        event = %Event{
          schema: rel.schema,
          table: rel.table,
          op: :update,
          new_row: new_row,
          old_row: old_row,
          lsn: txn_lsn,
          received_at: System.monotonic_time(:microsecond)
        }

        {[event], state}

      :not_found ->
        {[], state}
    end
  end

  defp do_decode(<<?D, oid::32, tuple_type::8, tuple::binary>>, {cache, txn_lsn} = state)
       when tuple_type in [?K, ?O] do
    case RelationCache.lookup(cache, oid) do
      {:ok, rel} ->
        {row, _} = decode_tuple(tuple, rel.columns)

        event = %Event{
          schema: rel.schema,
          table: rel.table,
          op: :delete,
          old_row: row,
          lsn: txn_lsn,
          received_at: System.monotonic_time(:microsecond)
        }

        {[event], state}

      :not_found ->
        {[], state}
    end
  end

  defp do_decode(<<?T, num_rels::32, _options::8, oids_bin::binary>>, {cache, txn_lsn} = state) do
    oids = for <<oid::32 <- binary_part(oids_bin, 0, num_rels * 4)>>, do: oid
    now = System.monotonic_time(:microsecond)

    events =
      Enum.flat_map(oids, fn oid ->
        case RelationCache.lookup(cache, oid) do
          {:ok, rel} ->
            [
              %Event{
                schema: rel.schema,
                table: rel.table,
                op: :truncate,
                lsn: txn_lsn,
                received_at: now
              }
            ]

          :not_found ->
            []
        end
      end)

    {events, state}
  end

  defp do_decode(<<?M, _flags::8, _lsn::64, rest::binary>>, {_cache, txn_lsn} = state) do
    {prefix, rest} = read_cstring(rest)
    <<content_len::32, content::binary-size(content_len)>> = rest

    event = %Event{
      op: :message,
      new_row: %{prefix: prefix, content: content},
      lsn: txn_lsn,
      received_at: System.monotonic_time(:microsecond)
    }

    {[event], state}
  end

  defp do_decode(_, state), do: {[], state}

  defp decode_update_tuples(<<?K, rest::binary>>, columns) do
    {old, <<?N, rest::binary>>} = decode_tuple_then_rest(rest, columns)
    {new, rest} = decode_tuple(rest, columns)
    {old, new, rest}
  end

  defp decode_update_tuples(<<?O, rest::binary>>, columns) do
    {old, <<?N, rest::binary>>} = decode_tuple_then_rest(rest, columns)
    {new, rest} = decode_tuple(rest, columns)
    {old, new, rest}
  end

  defp decode_update_tuples(<<?N, rest::binary>>, columns) do
    {new, rest} = decode_tuple(rest, columns)
    {nil, new, rest}
  end

  defp decode_tuple_then_rest(bin, columns) do
    {row, rest} = decode_tuple(bin, columns)
    {row, rest}
  end

  defp decode_tuple(<<num_cols::16, rest::binary>>, columns) do
    {values, rest} = decode_col_values(rest, num_cols, [])

    row =
      columns
      |> Enum.zip(values)
      |> Enum.flat_map(fn {col, val} ->
        case val do
          :null -> []
          :unchanged -> []
          v -> [{col.name, v}]
        end
      end)
      |> Map.new()

    {row, rest}
  end

  defp decode_col_values(rest, 0, acc), do: {Enum.reverse(acc), rest}

  defp decode_col_values(<<?n, rest::binary>>, n, acc),
    do: decode_col_values(rest, n - 1, [:null | acc])

  defp decode_col_values(<<?u, rest::binary>>, n, acc),
    do: decode_col_values(rest, n - 1, [:unchanged | acc])

  defp decode_col_values(<<?t, len::32, val::binary-size(len), rest::binary>>, n, acc),
    do: decode_col_values(rest, n - 1, [val | acc])

  defp decode_col_values(<<?b, len::32, val::binary-size(len), rest::binary>>, n, acc),
    do: decode_col_values(rest, n - 1, [val | acc])

  defp decode_columns(bin, 0, acc), do: {Enum.reverse(acc), bin}

  defp decode_columns(<<flags::8, rest::binary>>, n, acc) do
    {name, rest} = read_cstring(rest)
    <<_type_oid::32, _atttypmod::32, rest::binary>> = rest
    decode_columns(rest, n - 1, [%{name: name, flags: flags} | acc])
  end

  defp read_cstring(binary) do
    case :binary.split(binary, <<0>>) do
      [str, rest] -> {str, rest}
      [str] -> {str, <<>>}
    end
  end
end
