import Config

postgres_hostname = System.get_env("POSTGRES_HOSTNAME", "localhost")

config :restdis_server,
  resp_listen_ip: System.get_env("RESP_LISTEN_IP", "127.0.0.1")

config :restdis_buster,
  replication_connection: [
    hostname: postgres_hostname,
    username: "postgres",
    password: "postgres",
    database: "restdis_dev"
  ]

config :restdis_repo, RestdisRepo,
  username: "postgres",
  password: "postgres",
  hostname: postgres_hostname,
  database: "restdis_dev"
