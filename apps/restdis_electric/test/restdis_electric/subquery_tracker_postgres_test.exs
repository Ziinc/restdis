defmodule RestdisElectric.SubqueryTrackerPostgresTest do
  @moduledoc """
  The ELECTRIC_PRD Phase 6 item 1 acceptance test, against a real Postgres:
  a shape on `children` filtered by
  `parent_id IN (SELECT id FROM parents WHERE archived = false)` must
  incrementally drop a parent's children the moment the parent is archived,
  with no `409` — nothing about the children rows themselves changed, only
  the subquery's own result set did.

  Uses a real Postgres connection (via `RestdisElectric.Snapshotter.
  DirectPostgres`, the same one `log=changes_only` already requires) for
  every row `RestdisElectric.SubqueryTracker` reads. The WAL notification
  itself is simulated by calling `RestdisElectric.WAL.ingest/1` directly with
  a decoded change, exactly as `RestdisElectricTest`'s own WAL tests do:
  exercising the real replication pipeline is `restdis_buster`'s concern, not
  this context's.
  """

  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias RestdisElectric.TestUtils
  alias RestdisElectric.WAL

  @hostname System.get_env("POSTGRES_HOSTNAME", "localhost")
  @direct_pg_url "postgres://postgres:postgres@#{@hostname}:5432/restdis_test"

  defmodule TestRepo do
    @moduledoc false
    use Ecto.Repo, otp_app: :restdis_electric, adapter: Ecto.Adapters.Postgres
  end

  setup do
    case TestRepo.start_link(
           hostname: @hostname,
           username: "postgres",
           password: "postgres",
           database: "restdis_test"
         ) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    suffix = System.unique_integer([:positive])
    parents = "subquery_parents_#{suffix}"
    children = "subquery_children_#{suffix}"

    SQL.query!(
      TestRepo,
      "CREATE TABLE #{parents} (id int PRIMARY KEY, archived boolean NOT NULL)"
    )

    SQL.query!(TestRepo, "ALTER TABLE #{parents} REPLICA IDENTITY FULL")

    SQL.query!(TestRepo, """
    CREATE TABLE #{children} (id int PRIMARY KEY, parent_id int NOT NULL)
    """)

    SQL.query!(TestRepo, "ALTER TABLE #{children} REPLICA IDENTITY FULL")

    TestUtils.put_table("public.#{parents}", %{
      columns: ["id", "archived"],
      primary_key: ["id"],
      replica_identity: :full
    })

    TestUtils.put_table("public.#{children}", %{
      columns: ["id", "parent_id"],
      primary_key: ["id"],
      replica_identity: :full
    })

    # Reuses the direct pool for the outer shape's own snapshot too, so the test needs no PostgREST server.
    previous_reader = Application.get_env(:restdis_electric, :snapshot_reader)

    Application.put_env(
      :restdis_electric,
      :snapshot_reader,
      RestdisElectric.Snapshotter.DirectPostgres
    )

    on_exit(fn ->
      Application.put_env(:restdis_electric, :snapshot_reader, previous_reader)
    end)

    on_exit(fn ->
      {:ok, conn} =
        Postgrex.start_link(
          hostname: @hostname,
          username: "postgres",
          password: "postgres",
          database: "restdis_test"
        )

      Postgrex.query!(conn, "DROP TABLE IF EXISTS #{parents}", [])
      Postgrex.query!(conn, "DROP TABLE IF EXISTS #{children}", [])
      GenServer.stop(conn)
    end)

    %{parents: parents, children: children}
  end

  defp seed(table, rows) do
    for row <- rows do
      columns = Map.keys(row) |> Enum.join(", ")
      values = row |> Map.values() |> Enum.map_join(", ", &to_sql/1)
      SQL.query!(TestRepo, "INSERT INTO #{table} (#{columns}) VALUES (#{values})")
    end
  end

  defp to_sql(true), do: "true"
  defp to_sql(false), do: "false"
  defp to_sql(value) when is_integer(value), do: Integer.to_string(value)

  defp update!(table, id, sets) do
    assignments = Enum.map_join(sets, ", ", fn {col, val} -> "#{col} = #{to_sql(val)}" end)
    SQL.query!(TestRepo, "UPDATE #{table} SET #{assignments} WHERE id = #{id}")
  end

  test "archiving a parent removes its children from a subquery-filtered shape, with no 409", %{
    parents: parents,
    children: children
  } do
    tenant_id = TestUtils.tenant_id()

    seed(parents, [
      %{id: 1, archived: false},
      %{id: 2, archived: false}
    ])

    seed(children, [
      %{id: 10, parent_id: 1},
      %{id: 11, parent_id: 1},
      %{id: 20, parent_id: 2}
    ])

    tenant_config = %{direct_pg_url: @direct_pg_url}

    assert {:ok, subscribed} =
             RestdisElectric.subscribe(tenant_id, tenant_config, %{
               "table" => children,
               "offset" => "-1",
               "where" => "parent_id IN (SELECT id FROM #{parents} WHERE archived = false)"
             })

    inserted_ids = subscribed.messages |> Enum.map(& &1.value["id"]) |> Enum.sort()
    assert inserted_ids == [10, 11, 20]
    assert subscribed.up_to_date

    # Archiving parent 1: no 409, and its two children are removed incrementally.
    update!(parents, 1, archived: true)

    :ok =
      WAL.ingest(%{
        tenant_id: tenant_id,
        schema: "public",
        table: parents,
        op: :update,
        pk: 1,
        new_row: %{"id" => 1, "archived" => true},
        old_row: %{"id" => 1, "archived" => false},
        lsn: 100
      })

    assert {:ok, resumed} =
             RestdisElectric.subscribe(tenant_id, tenant_config, %{
               "table" => children,
               "handle" => subscribed.handle,
               "offset" => RestdisElectric.Offset.encode(subscribed.offset),
               "where" => "parent_id IN (SELECT id FROM #{parents} WHERE archived = false)"
             })

    deleted_ids =
      resumed.messages
      |> Enum.filter(&(&1.operation == :delete))
      |> Enum.map(& &1.value["id"])
      |> Enum.sort()

    assert deleted_ids == [10, 11]

    # Parent 2's child was never touched, and the shape stayed usable throughout: no must_refetch.
    refute Enum.any?(resumed.messages, &(&1.control == :must_refetch))
  end

  test "un-archiving a parent adds its children back", %{parents: parents, children: children} do
    tenant_id = TestUtils.tenant_id()

    # A second, already-matching parent/child keeps the snapshot non-empty, so there's a real offset to resume from.
    seed(parents, [%{id: 1, archived: true}, %{id: 2, archived: false}])
    seed(children, [%{id: 10, parent_id: 1}, %{id: 99, parent_id: 2}])

    tenant_config = %{direct_pg_url: @direct_pg_url}

    assert {:ok, subscribed} =
             RestdisElectric.subscribe(tenant_id, tenant_config, %{
               "table" => children,
               "offset" => "-1",
               "where" => "parent_id IN (SELECT id FROM #{parents} WHERE archived = false)"
             })

    assert Enum.map(subscribed.messages, & &1.value["id"]) == [99]

    update!(parents, 1, archived: false)

    :ok =
      WAL.ingest(%{
        tenant_id: tenant_id,
        schema: "public",
        table: parents,
        op: :update,
        pk: 1,
        new_row: %{"id" => 1, "archived" => false},
        old_row: %{"id" => 1, "archived" => true},
        lsn: 200
      })

    assert {:ok, resumed} =
             RestdisElectric.subscribe(tenant_id, tenant_config, %{
               "table" => children,
               "handle" => subscribed.handle,
               "offset" => RestdisElectric.Offset.encode(subscribed.offset),
               "where" => "parent_id IN (SELECT id FROM #{parents} WHERE archived = false)"
             })

    assert Enum.map(resumed.messages, &{&1.operation, &1.value["id"]}) == [{:insert, 10}]
  end
end
