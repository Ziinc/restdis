import Config

postgres_hostname = System.get_env("POSTGRES_HOSTNAME", "localhost")

config :restdis,
  cache_data_dir: System.tmp_dir!() <> "/restdis_test",
  origin: Restdis.Cache.Origin.Stub,
  ecto_repos: [Restdis.TestRepo]

config :restdis, Restdis.TestRepo,
  username: "postgres",
  password: "postgres",
  hostname: postgres_hostname,
  database: "restdis_lib_test",
  pool_size: 5,
  priv: "test/support/test_repo"
