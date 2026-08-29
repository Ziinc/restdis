defmodule Restdis.MigrationPublicationTest do
  use ExUnit.Case, async: false

  alias Restdis.TestRepo

  defmodule CreatePublicationMigration do
    use Ecto.Migration

    def up, do: Restdis.Migration.create_publication(name: "restdis_migration_test_pub")
    def down, do: Restdis.Migration.drop_publication(name: "restdis_migration_test_pub")
  end

  defmodule RerunPublicationMigration do
    use Ecto.Migration

    def up, do: Restdis.Migration.create_publication(name: "restdis_migration_test_pub")
    def down, do: :ok
  end

  defp publication_exists?(name) do
    {:ok, %{rows: rows}} =
      TestRepo.query("SELECT 1 FROM pg_publication WHERE pubname = $1", [name])

    rows != []
  end

  setup do
    on_exit(fn ->
      TestRepo.query!("DROP PUBLICATION IF EXISTS restdis_migration_test_pub")
    end)

    :ok
  end

  test "creates a FOR ALL TABLES publication" do
    version = System.unique_integer([:positive, :monotonic])
    Ecto.Migrator.up(TestRepo, version, CreatePublicationMigration, log: false)

    assert publication_exists?("restdis_migration_test_pub")
  end

  test "is safe to run twice" do
    version_1 = System.unique_integer([:positive, :monotonic])
    version_2 = System.unique_integer([:positive, :monotonic])

    Ecto.Migrator.up(TestRepo, version_1, CreatePublicationMigration, log: false)
    assert publication_exists?("restdis_migration_test_pub")

    # Applying the same helper again (as a distinct migration, the way a host might re-run it after a partial deploy) must not raise.
    Ecto.Migrator.up(TestRepo, version_2, RerunPublicationMigration, log: false)

    assert publication_exists?("restdis_migration_test_pub")
  end

  test "drop_publication/1 removes it" do
    version = System.unique_integer([:positive, :monotonic])
    Ecto.Migrator.up(TestRepo, version, CreatePublicationMigration, log: false)
    assert publication_exists?("restdis_migration_test_pub")

    Ecto.Migrator.down(TestRepo, version, CreatePublicationMigration, log: false)
    refute publication_exists?("restdis_migration_test_pub")
  end
end
