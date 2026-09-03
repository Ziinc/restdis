defmodule RestdisElectric.PostgrestDuplicateBoundTest do
  @moduledoc """
  Property test for the PostgREST/LSN-bracketing snapshot path (PRD point b):
  duplicates at the snapshot boundary are bounded by the writes that actually
  raced the snapshot, not unbounded, and the client's materialized view still
  converges to the same state a duplicate-free replay would produce.

  This exercises the real orchestration in `RestdisElectric.subscribe/3` — the
  same shape registration, `RestdisElectric.Snapshotter` page loop and
  `RestdisElectric.WAL.ingest/1` append path a live tenant uses — rather than
  reimplementing the bracketing logic. `RestdisElectric.Snapshotter.BracketingStub`
  only replaces the PostgREST HTTP origin with fixed rows, and injects a
  concurrent WAL write once per page, exactly where a real commit could land
  between `L0` and the snapshot reading that row.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias RestdisElectric.Snapshotter.BracketingStub
  alias RestdisElectric.TestSupport.MaterializedView
  alias RestdisElectric.TestUtils
  alias RestdisElectric.WAL

  @table "postgrest_bracketing_widgets"

  setup do
    TestUtils.put_table("public.#{@table}", %{
      columns: ["id", "name"],
      primary_key: ["id"],
      replica_identity: :full
    })

    previous_reader = Application.get_env(:restdis_electric, :snapshot_reader)
    Application.put_env(:restdis_electric, :snapshot_reader, BracketingStub)

    on_exit(fn ->
      Application.put_env(:restdis_electric, :snapshot_reader, previous_reader)
      Application.delete_env(:restdis_electric, :bracketing_during_page)
    end)

    :ok
  end

  defp row_gen do
    gen all(id <- integer(1..50), name <- string(:alphanumeric, min_length: 1, max_length: 5)) do
      %{"id" => id, "name" => name}
    end
  end

  property "duplicates are bounded by the writes that raced the snapshot, and the final state is exact" do
    check all(
            rows <- uniq_list_of(row_gen(), max_length: 12, uniq_fun: & &1["id"]),
            racing_ids <- list_of(integer(1..50), max_length: 12)
          ) do
      racing_ids =
        racing_ids |> Enum.filter(&Enum.any?(rows, fn row -> row["id"] == &1 end)) |> Enum.uniq()

      tenant_id = TestUtils.tenant_id()
      TestUtils.put_stub_rows(@table, rows)

      Application.put_env(:restdis_electric, :bracketing_during_page, fn ->
        racing_ids
        |> Enum.with_index()
        |> Enum.each(fn {id, index} ->
          row = Enum.find(rows, &(&1["id"] == id))

          # A commit for `id` lands after `L0` but before the snapshot's page is read, so both see it.
          :ok =
            WAL.ingest(%{
              tenant_id: tenant_id,
              schema: "public",
              table: @table,
              op: :insert,
              pk: id,
              new_row: row,
              old_row: nil,
              lsn: 100 + index
            })
        end)
      end)

      assert {:ok, result} =
               RestdisElectric.subscribe(tenant_id, %{}, %{"table" => @table, "offset" => "-1"})

      final_state = Enum.reduce(result.messages, %{}, &MaterializedView.apply_message(&2, &1))

      reference_state =
        Enum.reduce(rows, %{}, fn row, state ->
          MaterializedView.apply(state, :insert, to_string(row["id"]), row)
        end)

      duplicated_ids =
        result.messages
        |> Enum.map(& &1.key)
        |> Enum.frequencies()
        |> Enum.filter(fn {_key, count} -> count > 1 end)
        |> Enum.map(fn {key, _count} -> key end)

      # Every duplicate is one of the ids we made race the snapshot, so duplicates are bounded, not unbounded.
      assert length(duplicated_ids) <= length(racing_ids)
      assert Enum.all?(duplicated_ids, &(&1 in Enum.map(racing_ids, fn id -> to_string(id) end)))

      # Duplicates are safe: the client converges to exactly the state a duplicate-free replay from `-1` would reach.
      assert final_state == reference_state
    end
  end
end
