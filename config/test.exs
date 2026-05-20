import Config

config :supa_cacher_buster,
  slot_name: "supacacher_test_slot",
  publication_name: "supacacher_pub",
  az: "test",
  tenant_config_invalidator: nil,
  replication_connection: [
    hostname: "localhost",
    username: "postgres",
    password: "postgres",
    database: "supa_cacher_test"
  ]

config :supa_cacher_cache,
  cache_data_dir: System.tmp_dir!() <> "/supacacher_test",
  origin: SupaCacherCache.Origin.Stub,
  tenant_config_lookup: nil

config :supa_cacher_server,
  resp_port: 0,
  http_port: 0,
  tenant_store: SupaCacherServer.TenantStore.InMemory,
  req_options: [plug: {Req.Test, SupaCacherServer.Finch}]

config :supa_cacher_repo, SupaCacherRepo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "supa_cacher_test",
  pool: Ecto.Adapters.SQL.Sandbox
