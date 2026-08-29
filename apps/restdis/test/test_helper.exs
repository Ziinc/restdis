ExUnit.start()

test_dir =
  Application.get_env(
    :restdis,
    :cache_data_dir,
    System.tmp_dir!() <> "/restdis_test"
  )

File.rm_rf!(test_dir)

{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = Application.ensure_all_started(:postgrex)

# Recreate the test database on every run: migration tests assign version numbers with `System.unique_integer/1`, which restarts at 1 each VM boot, and a stale `schema_migrations` table left over from a previous run would make `Ecto.Migrator` believe those versions are already applied.
_ = Ecto.Adapters.Postgres.storage_down(Restdis.TestRepo.config())
:ok = Ecto.Adapters.Postgres.storage_up(Restdis.TestRepo.config())

{:ok, _pid} = Restdis.TestRepo.start_link()
