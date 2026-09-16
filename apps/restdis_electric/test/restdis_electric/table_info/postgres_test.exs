defmodule RestdisElectric.TableInfo.PostgresTest do
  @moduledoc """
  Defines its own tiny `Ecto.Repo`, rather than depending on any host
  application's repo, so `restdis_electric` stays boundary-clean (see
  `RestdisElectric.SchemaWatcherPostgresTest`).
  """

  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias RestdisElectric.TableInfo.Postgres, as: TableInfoPostgres
  alias RestdisElectric.TableInfo.PostgresTest.TestRepo

  defmodule TestRepo do
    @moduledoc false
    use Ecto.Repo, otp_app: :restdis_electric, adapter: Ecto.Adapters.Postgres
  end

  setup do
    # Unlink so one test's abnormal exit (e.g. a genuine SQL error) can't take down the shared `TestRepo`.
    pid =
      case TestRepo.start_link(
             hostname: System.get_env("POSTGRES_HOSTNAME", "localhost"),
             username: System.get_env("POSTGRES_USER", "postgres"),
             password: System.get_env("POSTGRES_PASSWORD", "postgres"),
             database: System.get_env("POSTGRES_DB", "restdis_test"),
             port: String.to_integer(System.get_env("POSTGRES_PORT", "5432"))
           ) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    Process.unlink(pid)

    previous_repo = Application.get_env(:restdis_electric, :repo)
    Application.put_env(:restdis_electric, :repo, TestRepo)
    on_exit(fn -> Application.put_env(:restdis_electric, :repo, previous_repo) end)

    :ok
  end

  defp unique_table(prefix), do: "#{prefix}_#{System.unique_integer([:positive, :monotonic])}"

  defp drop_on_exit(table) do
    on_exit(fn ->
      try do
        SQL.query!(TestRepo, "DROP TABLE IF EXISTS #{table}")
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end)
  end

  test "fetch/2 returns :error for a table that does not exist" do
    assert :error = TableInfoPostgres.fetch("public", "does_not_exist_#{System.unique_integer()}")
  end

  test "fetch/2 reads columns, primary key, replica identity and types" do
    table = unique_table("table_info_pg")
    drop_on_exit(table)
    SQL.query!(TestRepo, "CREATE TABLE #{table} (id int PRIMARY KEY, name text)")
    SQL.query!(TestRepo, "ALTER TABLE #{table} REPLICA IDENTITY FULL")

    assert {:ok, info} = TableInfoPostgres.fetch("public", table)
    assert info.columns == ["id", "name"]
    assert info.primary_key == ["id"]
    assert info.replica_identity == :full
    assert info.types["id"] =~ "integer"
    assert info.types["name"] == "text"
  end

  test "fetch/2 reports replica identity :nothing" do
    table = unique_table("table_info_pg_nothing")
    drop_on_exit(table)
    SQL.query!(TestRepo, "CREATE TABLE #{table} (id int PRIMARY KEY)")
    SQL.query!(TestRepo, "ALTER TABLE #{table} REPLICA IDENTITY NOTHING")

    assert {:ok, %{replica_identity: :nothing}} = TableInfoPostgres.fetch("public", table)
  end

  test "fetch/2 reports replica identity :index" do
    table = unique_table("table_info_pg_index")
    drop_on_exit(table)
    SQL.query!(TestRepo, "CREATE TABLE #{table} (id int PRIMARY KEY, name text NOT NULL)")
    SQL.query!(TestRepo, "CREATE UNIQUE INDEX #{table}_name_idx ON #{table} (name)")
    SQL.query!(TestRepo, "ALTER TABLE #{table} REPLICA IDENTITY USING INDEX #{table}_name_idx")

    assert {:ok, %{replica_identity: :index}} = TableInfoPostgres.fetch("public", table)
  end

  test "fetch/2 reports replica identity :default when left untouched" do
    table = unique_table("table_info_pg_default")
    drop_on_exit(table)
    SQL.query!(TestRepo, "CREATE TABLE #{table} (id int PRIMARY KEY)")

    assert {:ok, %{replica_identity: :default}} = TableInfoPostgres.fetch("public", table)
  end

  test "fetch/2 returns :error and logs a warning when the query raises" do
    previous_repo = Application.get_env(:restdis_electric, :repo)

    Application.put_env(
      :restdis_electric,
      :repo,
      RestdisElectric.TableInfo.PostgresTest.NoSuchRepo
    )

    on_exit(fn -> Application.put_env(:restdis_electric, :repo, previous_repo) end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :error = TableInfoPostgres.fetch("public", "whatever")
      end)

    assert log =~ "TableInfo.Postgres: query failed"
  end
end
