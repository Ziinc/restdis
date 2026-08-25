import Config

postgres_hostname = System.get_env("POSTGRES_HOSTNAME", "localhost")

config :supa_cacher_buster,
  slot_name: "supacacher_test_slot",
  publication_name: "supacacher_pub",
  az: "test",
  tenant_config_invalidator: nil,
  replication_dispatcher: nil,
  failover_reconciler: nil,
  replication_connection: [
    hostname: postgres_hostname,
    username: "postgres",
    password: "postgres",
    database: "supa_cacher_test"
  ],
  tenant_table_config_cache: [
    data_dir: System.tmp_dir!() <> "/supacacher_test/control_plane",
    ttl_ms: 60_000
  ]

config :supa_cacher_replicator,
  origin: SupaCacherReplicator.Origin.Stub,
  page_size: 2,
  page_delay_ms: 0,
  reconcile_stagger_ms: 0,
  dataset_source: nil,
  tenant_config_lookup: nil

config :restdis,
  cache_data_dir: System.tmp_dir!() <> "/supacacher_test",
  origin: Restdis.Cache.Origin.Stub,
  tenant_config_lookup: nil

config :supa_cacher_server,
  resp_port: 0,
  http_port: 0,
  tenant_store: SupaCacherServer.TenantStore.InMemory,
  tenant_config_cache: [
    data_dir: System.tmp_dir!() <> "/supacacher_test/control_plane",
    ttl_ms: 60_000
  ],
  req_options: [plug: {Req.Test, SupaCacherServer.Finch}],
  rewarm_tick_ms: 50

config :supa_cacher_repo, SupaCacherRepo,
  username: "postgres",
  password: "postgres",
  hostname: postgres_hostname,
  database: "supa_cacher_test",
  pool: Ecto.Adapters.SQL.Sandbox
