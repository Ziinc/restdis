defmodule Mix.Tasks.Restdis.Gen.MigrationTest do
  use ExUnit.Case, async: false

  @moduletag :db

  alias Mix.Tasks.Restdis.Gen.Migration, as: GenMigrationTask
  alias Restdis.TestRepo

  @tmp_dir Path.join(System.tmp_dir!(), "restdis_gen_migration_test")

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)

    on_exit(fn -> File.rm_rf!(@tmp_dir) end)

    :ok
  end

  test "generates a migration file calling Restdis.Migration.up/1 and down/1" do
    [file] =
      GenMigrationTask.run([
        "-r",
        "Restdis.TestRepo",
        "--migrations-path",
        @tmp_dir
      ])

    assert File.exists?(file)
    assert Path.basename(file) =~ ~r/^\d{14}_add_restdis\.exs$/

    content = File.read!(file)
    assert content =~ "use Ecto.Migration"
    assert content =~ "def up do"
    assert content =~ "Restdis.Migration.up(version: 1)"
    assert content =~ "def down do"
    assert content =~ "Restdis.Migration.down(version: 1)"
  end

  test "honours --prefix" do
    [file] =
      GenMigrationTask.run([
        "-r",
        "Restdis.TestRepo",
        "--migrations-path",
        @tmp_dir,
        "--prefix",
        "acme"
      ])

    content = File.read!(file)
    assert content =~ "Restdis.Migration.up(version: 1, prefix: \"acme\")"
    assert content =~ "Restdis.Migration.down(version: 1, prefix: \"acme\")"
  end

  test "refuses to generate twice in the same migrations directory" do
    GenMigrationTask.run([
      "-r",
      "Restdis.TestRepo",
      "--migrations-path",
      @tmp_dir
    ])

    assert_raise Mix.Error, ~r/already a migration file/, fn ->
      GenMigrationTask.run([
        "-r",
        "Restdis.TestRepo",
        "--migrations-path",
        @tmp_dir
      ])
    end
  end

  test "the generated file compiles and runs against a fresh database with no hand editing" do
    [file] =
      GenMigrationTask.run([
        "-r",
        "Restdis.TestRepo",
        "--migrations-path",
        @tmp_dir,
        "--prefix",
        "generated_test"
      ])

    on_exit(fn ->
      TestRepo.query!(~s(DROP SCHEMA IF EXISTS "generated_test" CASCADE))
    end)

    [{migration_module, _bin}] = Code.compile_file(file)

    version = System.unique_integer([:positive, :monotonic])
    Ecto.Migrator.up(TestRepo, version, migration_module, log: false)

    {:ok, %{rows: rows}} =
      TestRepo.query(
        "SELECT table_name FROM information_schema.tables WHERE table_schema = $1 ORDER BY table_name",
        ["generated_test"]
      )

    assert List.flatten(rows) == ["tenant_table_config", "tenants", "wal_checkpoint"]

    Ecto.Migrator.down(TestRepo, version, migration_module, log: false)

    {:ok, %{rows: rows_after_down}} =
      TestRepo.query(
        "SELECT table_name FROM information_schema.tables WHERE table_schema = $1",
        ["generated_test"]
      )

    assert rows_after_down == []
  end
end
