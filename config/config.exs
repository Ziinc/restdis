import Config

config :syn,
  scopes: [:wal, :wal_fanout]

config :restdis_buster,
  slot_name: "restdis_slot",
  publication_name: "restdis_pub",
  az: "local",
  tenant_config_invalidator: RestdisBuster.CompositeInvalidator,
  tenant_config_invalidator_chain: [
    Restdis.Cache.TenantInvalidator,
    RestdisServer.TenantStore.Invalidator
  ],
  tenant_table_config_cache: [data_dir: "./cache_data/control_plane", ttl_ms: 60_000],
  replication_dispatcher: RestdisReplicator.Dispatcher,
  failover_reconciler: RestdisReplicator.Reconciler

config :restdis,
  cache_data_dir: "./cache_data",
  origin: Restdis.Cache.Origin.Stub,
  replication_transport: Restdis.Cache.Replication.Transport.Distribution,
  tenant_config_lookup: {RestdisServer.TenantConfig, :lookup_by_tenant_id, []}

config :restdis_electric,
  repo: RestdisRepo,
  table_info: RestdisElectric.TableInfo.Postgres,
  snapshot_reader: RestdisElectric.Snapshotter.PostgREST

config :restdis_server,
  topologies: [],
  resp_port: 6380,
  http_port: 4040,
  tenant_store: RestdisServer.TenantStore.Repo,
  tenant_config_cache: [data_dir: "./cache_data/control_plane", ttl_ms: 60_000],
  postgrest_fetcher: RestdisServer.PostgREST.Fetcher.Req,
  rewarm_tick_ms: 500

config :restdis_replicator,
  origin: RestdisReplicator.Origin.Stub,
  page_size: 1000,
  page_delay_ms: 50,
  reconcile_stagger_ms: 1000,
  dataset_source: {RestdisReplicator.Datasets.Repo, :list_replicated, []},
  tenant_config_lookup: {RestdisServer.TenantConfig, :lookup_by_tenant_id, []}

config :restdis_repo,
  ecto_repos: [RestdisRepo]

config :restdis_repo, RestdisRepo, priv: "priv/repo"

config :opentelemetry,
  span_processor: :batch,
  traces_exporter: :otlp

config :opentelemetry_exporter,
  otlp_protocol: :http_protobuf,
  otlp_endpoint: "http://localhost:4318"

config :otel_metric_exporter,
  otlp_endpoint: "http://localhost:4318",
  export_period: 10_000,
  resource: %{"service.name" => "restdis"},
  metrics: [
    %{
      event_name: [:restdis_server, :rewarm, :cold_read],
      metric_name: [:restdis_server, :rewarm, :cold_read],
      measurement: :count,
      kind: :counter
    }
  ]

import_config "#{config_env()}.exs"
