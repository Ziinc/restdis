defmodule SupaCacherBuster.WAL.PgoutputTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias SupaCacherBuster.WAL.Event
  alias SupaCacherBuster.WAL.Pgoutput
  alias SupaCacherBuster.WAL.RelationCache

  # Binary frame builders

  defp relation_frame(oid, schema, table, cols) do
    num_cols = length(cols)

    col_bin =
      Enum.map_join(cols, fn %{name: name, flags: flags, type_oid: type_oid} ->
        <<flags::8, name::binary, 0, type_oid::32, -1::32-signed>>
      end)

    <<
      ?R,
      oid::32,
      schema::binary,
      0,
      table::binary,
      0,
      ?d,
      num_cols::16,
      col_bin::binary
    >>
  end

  defp text_col(value) when is_binary(value) do
    len = byte_size(value)
    <<?t, len::32, value::binary>>
  end

  defp null_col, do: <<?n>>

  defp insert_frame(oid, col_values_bin) do
    num_cols = div(byte_size(col_values_bin), 1)

    # count by parsing, simpler: just pass pre-built col_values_bin with an explicit count
    {count, _} = count_col_values(col_values_bin, 0)

    <<
      ?I,
      oid::32,
      ?N,
      count::16,
      col_values_bin::binary
    >>
  end

  defp count_col_values(<<>>, n), do: {n, <<>>}
  defp count_col_values(<<?n, rest::binary>>, n), do: count_col_values(rest, n + 1)
  defp count_col_values(<<?u, rest::binary>>, n), do: count_col_values(rest, n + 1)

  defp count_col_values(<<?t, len::32, _::binary-size(len), rest::binary>>, n),
    do: count_col_values(rest, n + 1)

  defp count_col_values(<<?b, len::32, _::binary-size(len), rest::binary>>, n),
    do: count_col_values(rest, n + 1)

  defp delete_frame(oid, col_values_bin) do
    {count, _} = count_col_values(col_values_bin, 0)

    <<
      ?D,
      oid::32,
      ?K,
      count::16,
      col_values_bin::binary
    >>
  end

  defp with_relation(oid, schema, table, cols) do
    cols_with_type = Enum.map(cols, fn name -> %{name: name, flags: 1, type_oid: 25} end)
    frame = relation_frame(oid, schema, table, cols_with_type)
    {events, cache} = Pgoutput.decode(frame, RelationCache.new())
    assert events == []
    {cols_with_type, cache}
  end

  test "Begin frame produces no events and preserves cache" do
    frame = <<?B, 100::64, 200::64, 1::32>>
    {events, _cache} = Pgoutput.decode(frame, RelationCache.new())
    assert events == []
  end

  test "Events between Begin and Commit carry the Begin's final_lsn" do
    final_lsn = 0xDEADBEEF
    {_cols, cache} = with_relation(10, "public", "products", ["id"])

    begin_frame = <<?B, final_lsn::64, 200::64, 1::32>>
    {[], state} = Pgoutput.decode(begin_frame, {cache, nil})

    col_values = text_col("42")
    ins_frame = insert_frame(10, col_values)

    {[event], state} = Pgoutput.decode(ins_frame, state)
    assert event.op == :insert
    assert event.lsn == final_lsn
    assert is_integer(event.received_at)

    commit_frame = <<?C, 0::8, final_lsn::64, final_lsn::64, 300::64>>
    {[], {_, txn_lsn_after}} = Pgoutput.decode(commit_frame, state)
    assert txn_lsn_after == nil
  end

  test "Commit frame produces no events" do
    frame = <<?C, 0::8, 100::64, 200::64, 300::64>>
    {events, _cache} = Pgoutput.decode(frame, RelationCache.new())
    assert events == []
  end

  test "Relation frame updates cache and produces no events" do
    frame = relation_frame(42, "public", "products", [%{name: "id", flags: 1, type_oid: 23}])
    {events, cache} = Pgoutput.decode(frame, RelationCache.new())
    assert events == []
    assert {:ok, %{schema: "public", table: "products"}} = RelationCache.lookup(cache, 42)
  end

  test "Insert frame decodes row and emits :insert event" do
    {cols, cache} = with_relation(10, "public", "products", ["id", "name"])
    _ = cols

    col_values = <<text_col("42")::binary, text_col("Widget")::binary>>
    frame = insert_frame(10, col_values)

    {[event], _cache} = Pgoutput.decode(frame, cache)
    assert %Event{op: :insert, schema: "public", table: "products"} = event
    assert event.new_row["id"] == "42"
    assert event.new_row["name"] == "Widget"
    assert is_nil(event.old_row)
  end

  test "Insert frame with null column omits null from row map" do
    {_cols, cache} = with_relation(10, "public", "products", ["id", "name"])

    col_values = <<text_col("99")::binary, null_col()::binary>>
    frame = insert_frame(10, col_values)

    {[event], _} = Pgoutput.decode(frame, cache)
    assert event.new_row["id"] == "99"
    refute Map.has_key?(event.new_row, "name")
  end

  test "Delete frame with K tuple emits :delete event with old_row" do
    {_cols, cache} = with_relation(10, "public", "orders", ["id"])

    col_values = text_col("7")
    frame = delete_frame(10, col_values)

    {[event], _} = Pgoutput.decode(frame, cache)
    assert %Event{op: :delete, table: "orders"} = event
    assert event.old_row["id"] == "7"
    assert is_nil(event.new_row)
  end

  test "Update frame with N-only tuple emits :update with nil old_row" do
    {_cols, cache} = with_relation(10, "public", "products", ["id", "name"])

    col_values = <<text_col("1")::binary, text_col("Updated")::binary>>
    {count, _} = count_col_values(col_values, 0)
    frame = <<?U, 10::32, ?N, count::16, col_values::binary>>

    {[event], _} = Pgoutput.decode(frame, cache)
    assert event.op == :update
    assert event.new_row["id"] == "1"
    assert is_nil(event.old_row)
  end

  test "Update frame with K old tuple emits :update with both rows" do
    {_cols, cache} = with_relation(10, "public", "products", ["id", "name"])

    old_values = <<text_col("1")::binary, text_col("Old")::binary>>
    {old_count, _} = count_col_values(old_values, 0)
    new_values = <<text_col("1")::binary, text_col("New")::binary>>
    {new_count, _} = count_col_values(new_values, 0)

    frame =
      <<?U, 10::32, ?K, old_count::16, old_values::binary, ?N, new_count::16, new_values::binary>>

    {[event], _} = Pgoutput.decode(frame, cache)
    assert event.op == :update
    assert event.old_row["name"] == "Old"
    assert event.new_row["name"] == "New"
  end

  test "Truncate frame emits :truncate events for each OID" do
    {_cols, cache} =
      Pgoutput.decode(
        relation_frame(1, "public", "a", [%{name: "id", flags: 1, type_oid: 23}]),
        RelationCache.new()
      )
      |> then(fn {[], c} -> {nil, c} end)

    {[], cache} =
      Pgoutput.decode(
        relation_frame(2, "public", "b", [%{name: "id", flags: 1, type_oid: 23}]),
        cache
      )

    frame = <<?T, 2::32, 0::8, 1::32, 2::32>>
    {events, _} = Pgoutput.decode(frame, cache)
    tables = Enum.map(events, & &1.table)
    assert "a" in tables
    assert "b" in tables
    assert Enum.all?(events, &(&1.op == :truncate))
  end

  test "Message frame emits :message event with prefix and content" do
    prefix = "ddl_change"
    content = ~s({"table":"products","op":"drop"})
    content_len = byte_size(content)

    frame = <<
      ?M,
      0::8,
      0::64,
      prefix::binary,
      0,
      content_len::32,
      content::binary
    >>

    {[event], _} = Pgoutput.decode(frame, RelationCache.new())
    assert event.op == :message
    assert event.new_row.prefix == prefix
    assert event.new_row.content == content
  end

  test "Unknown message type produces no events" do
    {events, _} = Pgoutput.decode(<<?Z, 1, 2, 3>>, RelationCache.new())
    assert events == []
  end

  test "Insert for unknown OID produces no events" do
    col_values = text_col("1")
    {count, _} = count_col_values(col_values, 0)
    frame = <<?I, 999::32, ?N, count::16, col_values::binary>>
    {events, _} = Pgoutput.decode(frame, RelationCache.new())
    assert events == []
  end

  property "Relation then Insert always produces exactly one :insert event" do
    check all(
            oid <- positive_integer(),
            schema <- string(:alphanumeric, min_length: 1),
            table <- string(:alphanumeric, min_length: 1),
            value <- string(:alphanumeric)
          ) do
      rel_frame = relation_frame(oid, schema, table, [%{name: "id", flags: 1, type_oid: 23}])
      {[], cache} = Pgoutput.decode(rel_frame, RelationCache.new())

      col_values = text_col(value)
      {count, _} = count_col_values(col_values, 0)
      ins_frame = <<?I, oid::32, ?N, count::16, col_values::binary>>
      {events, _} = Pgoutput.decode(ins_frame, cache)

      assert length(events) == 1
      assert hd(events).op == :insert
      assert hd(events).schema == schema
      assert hd(events).table == table
    end
  end
end
