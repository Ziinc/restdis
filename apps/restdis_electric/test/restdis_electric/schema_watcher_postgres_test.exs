defmodule RestdisElectric.SchemaWatcherPostgresTest do
  @moduledoc """
  The PRD scenario for periodic schema-drift detection, against a real
  Postgres: a column added by `ALTER TABLE` produces no WAL notification, so
  only the periodic comparison this module implements catches it and
  invalidates the shape.

  Defines its own tiny `Ecto.Repo`, rather than depending on any host
  application's repo, so `restdis_electric` stays boundary-clean.
  """

  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias RestdisElectric.Log
  alias RestdisElectric.Offset
  alias RestdisElectric.SchemaWatcher
  alias RestdisElectric.SchemaWatcherPostgresTest.TestRepo
  alias RestdisElectric.ShapeRegistry
  alias RestdisElectric.TableInfo
  alias RestdisElectric.TestUtils

  defmodule TestRepo do
    @moduledoc false
    use Ecto.Repo, otp_app: :restdis_electric, adapter: Ecto.Adapters.Postgres
  end

  setup do
    {:ok, _pid} =
      TestRepo.start_link(
        hostname: System.get_env("POSTGRES_HOSTNAME", "localhost"),
        username: System.get_env("POSTGRES_USER", "postgres"),
        password: System.get_env("POSTGRES_PASSWORD", "postgres"),
        database: System.get_env("POSTGRES_DB", "restdis_test"),
        port: String.to_integer(System.get_env("POSTGRES_PORT", "5432"))
      )

    table = "schema_watcher_drift_#{System.unique_integer([:positive])}"
    SQL.query!(TestRepo, "CREATE TABLE #{table} (id int PRIMARY KEY)")
    SQL.query!(TestRepo, "ALTER TABLE #{table} REPLICA IDENTITY FULL")

    previous_table_info = Application.get_env(:restdis_electric, :table_info)
    previous_repo = Application.get_env(:restdis_electric, :repo)

    Application.put_env(:restdis_electric, :table_info, RestdisElectric.TableInfo.Postgres)
    Application.put_env(:restdis_electric, :repo, TestRepo)

    on_exit(fn ->
      Application.put_env(:restdis_electric, :table_info, previous_table_info)
      Application.put_env(:restdis_electric, :repo, previous_repo)
    end)

    %{table: table}
  end

  test "adding a column with no WAL notification invalidates the shape within one poll", %{
    table: table
  } do
    tenant_id = TestUtils.tenant_id()
    handle = "drift-#{table}"
    server = :"schema_watcher_#{table}"

    :ok = ShapeRegistry.register(tenant_id, "public", table, handle)
    {:ok, _pid} = Log.ensure_started(tenant_id, handle)

    {:ok, _pid} = SchemaWatcher.start_link(name: server, interval_ms: 20)

    # First pass establishes the baseline snapshot; the shape must still be there.
    :ok = SchemaWatcher.check(server)
    assert {:ok, _} = ShapeRegistry.fetch(tenant_id, handle)

    SQL.query!(TestRepo, "ALTER TABLE #{table} ADD COLUMN extra text")

    # No WAL event was produced by the ALTER TABLE above; only the periodic comparison detects this, on its next poll.
    assert {:ok, _} = TableInfo.fetch("public", table)

    # Drive the poll synchronously with `check/1` instead of racing the timer with `Process.sleep/1`.
    :ok = SchemaWatcher.check(server)

    assert ShapeRegistry.fetch(tenant_id, handle) == :error
    assert Log.read(tenant_id, handle, Offset.beginning()) == :error
  end
end
