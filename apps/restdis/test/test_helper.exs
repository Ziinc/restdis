run_db_tests? = System.get_env("RESTDIS_SKIP_DB_TESTS") != "true"

ExUnit.start(exclude: if(run_db_tests?, do: [], else: [:db]))

{:ok, _pid} = Restdis.Cache.Supervisor.start_link([])

test_dir =
  Application.get_env(
    :restdis,
    :cache_data_dir,
    System.tmp_dir!() <> "/restdis_test"
  )

File.rm_rf!(test_dir)

if run_db_tests? do
  {:ok, _} = Application.ensure_all_started(:ecto_sql)
  {:ok, _} = Application.ensure_all_started(:postgrex)

  # Recreate the DB every run: a stale `schema_migrations` table would fool `Ecto.Migrator` about applied versions.
  _ = Ecto.Adapters.Postgres.storage_down(Restdis.TestRepo.config())
  :ok = Ecto.Adapters.Postgres.storage_up(Restdis.TestRepo.config())

  {:ok, _pid} = Restdis.TestRepo.start_link()
end
