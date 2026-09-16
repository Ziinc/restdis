defmodule Restdis.MigrationTest do
  use ExUnit.Case, async: false

  @moduletag :db

  alias Restdis.TestRepo

  defmodule DefaultPrefixMigration do
    use Ecto.Migration

    def up, do: Restdis.Migration.up(version: 1)
    def down, do: Restdis.Migration.down(version: 1)
  end

  defmodule CustomPrefixMigration do
    use Ecto.Migration

    def up, do: Restdis.Migration.up(version: 1, prefix: "custom_restdis")
    def down, do: Restdis.Migration.down(version: 1, prefix: "custom_restdis")
  end

  defmodule DoubleUpMigration do
    use Ecto.Migration

    def up do
      Restdis.Migration.up(version: 1)
      Restdis.Migration.up(version: 1)
    end

    def down, do: Restdis.Migration.down(version: 1)
  end

  defp run_up(migration_module, prefix) do
    version = System.unique_integer([:positive, :monotonic])
    Ecto.Migrator.up(TestRepo, version, migration_module, log: false)
    on_exit_drop(prefix)
    version
  end

  defp on_exit_drop(prefix) do
    ExUnit.Callbacks.on_exit(fn ->
      TestRepo.query!(~s(DROP SCHEMA IF EXISTS "#{prefix}" CASCADE))
    end)
  end

  defp tables(prefix) do
    {:ok, %{rows: rows}} =
      TestRepo.query(
        "SELECT table_name FROM information_schema.tables WHERE table_schema = $1",
        [prefix]
      )

    rows |> List.flatten() |> Enum.sort()
  end

  describe "up/1 with the default prefix" do
    test "creates tenants, tenant_table_config and wal_checkpoint" do
      run_up(DefaultPrefixMigration, "restdis")

      assert tables("restdis") == ["tenant_table_config", "tenants", "wal_checkpoint"]
    end

    test "is idempotent: calling up/1 twice at the same version is a no-op the second time" do
      run_up(DoubleUpMigration, "restdis")

      assert tables("restdis") == ["tenant_table_config", "tenants", "wal_checkpoint"]
      assert Restdis.Migration.migrated_version(repo: TestRepo) == 1
    end

    test "migrated_version/1 reports the applied version" do
      run_up(DefaultPrefixMigration, "restdis")

      assert Restdis.Migration.migrated_version(repo: TestRepo) == 1
    end

    test "migrated_version/1 reports 0 before anything has run" do
      assert Restdis.Migration.migrated_version(prefix: "restdis_never_migrated", repo: TestRepo) ==
               0
    end
  end

  describe "up/1 then down/1 then up/1" do
    test "leaves the schema identical" do
      version = run_up(DefaultPrefixMigration, "restdis")
      tables_after_first_up = tables("restdis")

      Ecto.Migrator.down(TestRepo, version, DefaultPrefixMigration, log: false)
      assert tables("restdis") == []
      assert Restdis.Migration.migrated_version(repo: TestRepo) == 0

      Ecto.Migrator.up(TestRepo, version, DefaultPrefixMigration, log: false)
      assert tables("restdis") == tables_after_first_up
      assert Restdis.Migration.migrated_version(repo: TestRepo) == 1
    end
  end

  describe "with a custom prefix" do
    test "creates the tables under the given schema and leaves the default alone" do
      run_up(CustomPrefixMigration, "custom_restdis")

      assert tables("custom_restdis") == ["tenant_table_config", "tenants", "wal_checkpoint"]
      assert tables("restdis") == []
      assert Restdis.Migration.migrated_version(prefix: "custom_restdis", repo: TestRepo) == 1
    end
  end
end
