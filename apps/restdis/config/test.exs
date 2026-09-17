import Config

postgres_hostname = System.get_env("POSTGRES_HOSTNAME", "localhost")

config :restdis,
  ecto_repos: [Restdis.TestRepo]

config :restdis, Restdis.TestRepo,
  username: "postgres",
  password: "postgres",
  hostname: postgres_hostname,
  database: "restdis_lib_test",
  pool_size: 5,
  priv: "test/support/test_repo"
