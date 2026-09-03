defmodule RestdisElectric.SnapshotConsistencyTest do
  @moduledoc """
  Property tests for the Phase 5 consistency guarantees: on the direct
  Postgres path, no row appears both in the snapshot and as an early logged
  insert (point 2/3 of the PRD phase); and a client using `changes_only`
  builds the same final data as a client using `full`, given the same
  underlying rows and the same buffered WAL transactions (point 4).
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias RestdisElectric.SnapshotDescriptor
  alias RestdisElectric.TestSupport.MaterializedView

  # A toy row: an id, the xid of the transaction that most recently wrote it, and its value.
  defp row_gen do
    gen all(id <- integer(1..20), xid <- integer(1..200), value <- integer(0..1_000)) do
      %{id: id, xid: xid, value: value}
    end
  end

  # `apply_row/2` models a client's materialized view: insert/update by id, keyed on the row's `id`.
  defp apply_row(state, %{id: id, value: value}),
    do: MaterializedView.apply(state, :insert, id, value)

  property "a row visible in the snapshot is never also logged as an early insert" do
    check all(
            xmin <- integer(1..100),
            span <- integer(1..100),
            rows <- list_of(row_gen(), max_length: 30)
          ) do
      xmax = xmin + span
      descriptor = %{xmin: xmin, xmax: xmax, xip_list: []}

      # The buffered WAL stream arrives in commit order, which increases the transaction identifier.
      rows = Enum.sort_by(rows, & &1.xid)

      # The snapshot contains exactly the rows whose xid is visible under the descriptor.
      snapshot_rows = Enum.filter(rows, &SnapshotDescriptor.visible?(descriptor, &1.xid))

      # The buffered WAL stream is decided against the same descriptor, via a fresh cursor per shape.
      cursor = SnapshotDescriptor.new_cursor(descriptor)

      {logged_rows, _cursor} =
        Enum.reduce(rows, {[], cursor}, fn row, {logged, cursor} ->
          case SnapshotDescriptor.decide(cursor, row.xid) do
            {:log, cursor} -> {[row | logged], cursor}
            {:skip, cursor} -> {logged, cursor}
          end
        end)

      duplicated = MapSet.intersection(MapSet.new(snapshot_rows), MapSet.new(logged_rows))
      assert Enum.empty?(duplicated)
    end
  end

  property "changes_only and full converge to the same final materialized data" do
    check all(
            xmin <- integer(1..100),
            span <- integer(1..100),
            rows <- list_of(row_gen(), max_length: 20)
          ) do
      xmax = xmin + span
      descriptor = %{xmin: xmin, xmax: xmax, xip_list: []}

      # Every transaction the shape will ever see, in commit order: some land in the snapshot, the rest replay later.
      rows = Enum.sort_by(rows, & &1.xid)

      # `full`: starts empty, gets the snapshot's visible rows, then every row `decide` logs.
      snapshot_rows = Enum.filter(rows, &SnapshotDescriptor.visible?(descriptor, &1.xid))
      full_after_snapshot = Enum.reduce(snapshot_rows, %{}, &apply_row(&2, &1))
      full_final = replay(full_after_snapshot, rows, descriptor)

      # `changes_only`: the client already has every row via its own direct replica, then applies only logged rows.
      changes_only_base = Enum.reduce(rows, %{}, &apply_row(&2, &1))
      changes_only_final = replay(changes_only_base, rows, descriptor)

      assert full_final == changes_only_final
    end
  end

  defp replay(state, wal_rows, descriptor) do
    cursor = SnapshotDescriptor.new_cursor(descriptor)

    {final, _cursor} =
      Enum.reduce(wal_rows, {state, cursor}, fn row, {state, cursor} ->
        case SnapshotDescriptor.decide(cursor, row.xid) do
          {:log, cursor} -> {apply_row(state, row), cursor}
          {:skip, cursor} -> {state, cursor}
        end
      end)

    final
  end

  describe "wired end-to-end through RestdisElectric.subscribe" do
    alias RestdisElectric.Snapshotter.DirectPostgres
    alias RestdisElectric.TestUtils
    alias RestdisElectric.WAL

    @direct_pg_url "postgres://postgres:postgres@#{System.get_env("POSTGRES_HOSTNAME", "localhost")}:5432/restdis_test"

    setup do
      {:ok, conn} = Postgrex.start_link(DirectPostgres.connect_opts(@direct_pg_url))
      Postgrex.query!(conn, "DROP TABLE IF EXISTS consistency_widgets", [])

      Postgrex.query!(
        conn,
        "CREATE TABLE consistency_widgets (id integer PRIMARY KEY, name text)",
        []
      )

      Postgrex.query!(
        conn,
        "INSERT INTO consistency_widgets (id, name) VALUES (1, 'a'), (2, 'b')",
        []
      )

      on_exit(fn ->
        {:ok, conn} = Postgrex.start_link(DirectPostgres.connect_opts(@direct_pg_url))
        Postgrex.query!(conn, "DROP TABLE IF EXISTS consistency_widgets", [])
      end)

      TestUtils.put_table("public.consistency_widgets", %{
        columns: ["id", "name"],
        primary_key: ["id"],
        replica_identity: :full
      })

      TestUtils.put_stub_rows("consistency_widgets", [
        %{"id" => 1, "name" => "a"},
        %{"id" => 2, "name" => "b"}
      ])

      :ok
    end

    # `changes_only` starts from the table's real rows, its own replica's stand-in; `full` starts from its snapshot.
    test "full and changes_only converge to the same materialized state after a live change" do
      tenant_id = TestUtils.tenant_id()
      tenant_config = %{direct_pg_url: @direct_pg_url}

      assert {:ok, full} =
               RestdisElectric.subscribe(tenant_id, tenant_config, %{
                 "table" => "consistency_widgets",
                 "offset" => "-1"
               })

      full_state = Enum.reduce(full.messages, %{}, &MaterializedView.apply_message(&2, &1))

      assert {:ok, changes_only} =
               RestdisElectric.subscribe(tenant_id, tenant_config, %{
                 "table" => "consistency_widgets",
                 "offset" => "-1",
                 "log" => "changes_only"
               })

      # `changes_only` never sends row inserts, only the snapshot-end control message.
      assert Enum.all?(changes_only.messages, &RestdisElectric.Message.control?/1)

      changes_only_state = %{
        "1" => %{"id" => 1, "name" => "a"},
        "2" => %{"id" => 2, "name" => "b"}
      }

      :ok =
        WAL.ingest(%{
          tenant_id: tenant_id,
          schema: "public",
          table: "consistency_widgets",
          op: :update,
          pk: 1,
          new_row: %{"id" => 1, "name" => "changed"},
          old_row: %{"id" => 1, "name" => "a"},
          lsn: 100
        })

      {:ok, full_new_messages, _offset} =
        RestdisElectric.Log.read(tenant_id, full.handle, full.offset)

      {:ok, changes_only_new_messages, _offset} =
        RestdisElectric.Log.read(tenant_id, changes_only.handle, changes_only.offset)

      full_final =
        Enum.reduce(full_new_messages, full_state, &MaterializedView.apply_message(&2, &1))

      changes_only_final =
        Enum.reduce(
          changes_only_new_messages,
          changes_only_state,
          &MaterializedView.apply_message(&2, &1)
        )

      assert full_final == changes_only_final

      assert full_final == %{
               "1" => %{"id" => 1, "name" => "changed"},
               "2" => %{"id" => 2, "name" => "b"}
             }
    end
  end
end
