import Config

config :supa_cacher_buster,
  replication_connection: [
    hostname: "localhost",
    username: "postgres",
    password: "postgres",
    database: "supa_cacher_dev"
  ]

config :supa_cacher_repo, SupaCacherRepo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "supa_cacher_dev"
