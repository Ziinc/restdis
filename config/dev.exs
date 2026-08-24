import Config

postgres_hostname = System.get_env("POSTGRES_HOSTNAME", "localhost")

config :supa_cacher_buster,
  replication_connection: [
    hostname: postgres_hostname,
    username: "postgres",
    password: "postgres",
    database: "supa_cacher_dev"
  ]

config :supa_cacher_repo, SupaCacherRepo,
  username: "postgres",
  password: "postgres",
  hostname: postgres_hostname,
  database: "supa_cacher_dev"
