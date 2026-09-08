import Config

postgres_hostname = System.get_env("RESTDIS_POSTGRES_HOSTNAME", "localhost")

# The Electric conformance harness (demos/electric/conformance) has no PostgREST instance to read snapshots through, so it points this at a tenant's `direct_pg_url` instead; every other `dev` run keeps the default `config/config.exs` PostgREST reader.
if System.get_env("RESTDIS_SNAPSHOT_READER") == "direct_postgres" do
  config :restdis_electric, snapshot_reader: RestdisElectric.Snapshotter.DirectPostgres
end

config :restdis_server,
  resp_listen_ip: System.get_env("RESTDIS_RESP_LISTEN_IP", "127.0.0.1")

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
