import Config

config :syn,
  scopes: [:wal, :wal_fanout]

config :supa_cacher_buster,
  slot_name: "supacacher_slot",
  publication_name: "supacacher_pub",
  az: "local",
  tenant_config_invalidator: SupaCacherBuster.CompositeInvalidator,
  tenant_config_invalidator_chain: [
    Restdis.Cache.TenantInvalidator,
    SupaCacherServer.TenantStore.Invalidator
  ],
  tenant_table_config_cache: [data_dir: "./cache_data/control_plane", ttl_ms: 60_000],
  replication_dispatcher: SupaCacherReplicator.Dispatcher,
  failover_reconciler: SupaCacherReplicator.Reconciler

config :restdis,
  cache_data_dir: "./cache_data",
  origin: Restdis.Cache.Origin.Stub,
  replication_transport: Restdis.Cache.Replication.Transport.Distribution,
  tenant_config_lookup: {SupaCacherServer.TenantConfig, :lookup_by_tenant_id, []}

config :supa_cacher_server,
  topologies: [],
  resp_port: 6380,
  http_port: 4040,
  tenant_store: SupaCacherServer.TenantStore.Repo,
  tenant_config_cache: [data_dir: "./cache_data/control_plane", ttl_ms: 60_000],
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

config :supa_cacher_repo, SupaCacherRepo, priv: "priv/repo"

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
      event_name: [:supa_cacher_server, :rewarm, :cold_read],
      metric_name: [:supa_cacher_server, :rewarm, :cold_read],
      measurement: :count,
      kind: :counter
    }
  ]

import_config "#{config_env()}.exs"
