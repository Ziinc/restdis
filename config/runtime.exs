import Config

service_name = System.get_env("OTEL_SERVICE_NAME", "restdis")

config :opentelemetry, resource: %{"service.name" => service_name}

if otlp_endpoint = System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT") do
  config :opentelemetry_exporter, otlp_endpoint: otlp_endpoint
  config :otel_metric_exporter, otlp_endpoint: otlp_endpoint
end

config :otel_metric_exporter, resource: %{"service.name" => service_name}

if System.get_env("RESTDIS_JSON_LOGGER", "false") in ~w(true 1) do
  config :logger, :default_handler,
    formatter: LoggerJSON.Formatters.Basic.new(metadata: :all)
end

if config_env() == :prod do
  config :supa_cacher_buster,
    az: System.get_env("RELEASE_AZ", "local"),
    slot_name: System.get_env("WAL_SLOT_NAME", "supacacher_slot"),
    publication_name: System.get_env("WAL_PUBLICATION_NAME", "supacacher_pub"),
    replication_connection: [
      url: System.fetch_env!("DATABASE_URL"),
      pool_size: 1
    ]

  config :supa_cacher_cache,
    cache_data_dir: System.get_env("CACHE_DATA_DIR", "/var/lib/supacacher/cache"),
    origin: SupaCacherCache.Origin.PostgREST

  config :supa_cacher_replicator,
    origin: SupaCacherReplicator.Origin.PostgREST,
    page_size: String.to_integer(System.get_env("REPLICATION_PAGE_SIZE", "1000")),
    page_delay_ms: String.to_integer(System.get_env("REPLICATION_PAGE_DELAY_MS", "50")),
    reconcile_stagger_ms:
      String.to_integer(System.get_env("REPLICATION_RECONCILE_STAGGER_MS", "1000"))

  config :supa_cacher_server,
    resp_port: String.to_integer(System.get_env("RESP_PORT", "6380")),
    http_port: String.to_integer(System.get_env("HTTP_PORT", "4040")),
    tenant_store: SupaCacherServer.TenantStore.Repo

  config :supa_cacher_repo, SupaCacherRepo,
    url: System.fetch_env!("DATABASE_URL"),
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "10"))
end
