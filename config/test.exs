import Config

postgres_hostname = System.get_env("POSTGRES_HOSTNAME", "localhost")

config :restdis_buster,
  slot_name: "restdis_test_slot",
  publication_name: "restdis_pub",
  az: "test",
  tenant_config_invalidator: nil,
  replication_dispatcher: nil,
  failover_reconciler: nil,
  replication_connection: [
    hostname: postgres_hostname,
    username: "postgres",
    password: "postgres",
    database: "restdis_test"
  ],
  tenant_table_config_cache: [
    data_dir: System.tmp_dir!() <> "/restdis_test/control_plane",
    ttl_ms: 60_000
  ]

config :restdis_replicator,
  origin: RestdisReplicator.Origin.Stub,
  page_size: 2,
  page_delay_ms: 0,
  reconcile_stagger_ms: 0,
  dataset_source: nil,
  tenant_config_lookup: nil

config :restdis,
  tenant_config_lookup: nil,
  ecto_repos: [Restdis.TestRepo]

config :restdis_electric,
  table_info: RestdisElectric.TableInfo.Static,
  snapshot_reader: RestdisElectric.Snapshotter.Stub,
  tables: %{},
  stub_rows: %{}

# Exercises `Restdis.Migration` against a real repo. Kept in sync with `apps/restdis/config/test.exs`.
config :restdis, Restdis.TestRepo,
  username: "postgres",
  password: "postgres",
  hostname: postgres_hostname,
  database: "restdis_lib_test",
  pool_size: 5,
  priv: "test/support/test_repo"

config :restdis_server,
  resp_port: 0,
  http_port: 0,
  tenant_store: RestdisServer.TenantStore.InMemory,
  tenant_config_cache: [
    data_dir: System.tmp_dir!() <> "/restdis_test/control_plane",
    ttl_ms: 60_000
  ],
  req_options: [plug: {Req.Test, RestdisServer.Finch}],
  rewarm_tick_ms: 50,
  cache_data_dir: System.tmp_dir!() <> "/restdis_test",
  cache_origin: Restdis.Cache.Origin.Stub

config :restdis_repo, RestdisRepo,
  username: "postgres",
  password: "postgres",
  hostname: postgres_hostname,
  database: "restdis_test",
  pool: Ecto.Adapters.SQL.Sandbox
