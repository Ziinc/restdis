import Config

config :syn,
  scopes: [:wal, :wal_fanout]

config :supa_cacher_buster,
  slot_name: "supacacher_slot",
  publication_name: "supacacher_pub",
  az: "local",
  tenant_config_invalidator: SupaCacherBuster.CompositeInvalidator,
  tenant_config_invalidator_chain: [
    SupaCacherCache.TenantInvalidator,
    SupaCacherServer.TenantStore.Invalidator
  ],
  replication_dispatcher: SupaCacherReplicator.Dispatcher,
  failover_reconciler: SupaCacherReplicator.Reconciler

config :supa_cacher_cache,
  cache_data_dir: "./cache_data",
  origin: SupaCacherCache.Origin.Stub,
  replication_transport: SupaCacherCache.Replication.Transport.Distribution,
  tenant_config_lookup: {SupaCacherServer.TenantConfig, :lookup_by_tenant_id, []}

config :supa_cacher_server,
  resp_port: 6380,
  http_port: 4040,
  tenant_store: SupaCacherServer.TenantStore.Repo,
  postgrest_fetcher: SupaCacherServer.PostgREST.Fetcher.Req,
  rewarm_tick_ms: 500

config :supa_cacher_replicator,
  origin: SupaCacherReplicator.Origin.Stub,
  page_size: 1000,
  page_delay_ms: 50,
  reconcile_stagger_ms: 1000,
  dataset_source: {SupaCacherReplicator.Datasets.Repo, :list_replicated, []},
  tenant_config_lookup: {SupaCacherServer.TenantConfig, :lookup_by_tenant_id, []}

config :supa_cacher_repo,
  ecto_repos: [SupaCacherRepo]

import_config "#{config_env()}.exs"
