import Config

service_name = System.get_env("OTEL_SERVICE_NAME", "restdis")

config :opentelemetry, resource: %{"service.name" => service_name}

if otlp_endpoint = System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT") do
  config :opentelemetry_exporter, otlp_endpoint: otlp_endpoint
  config :otel_metric_exporter, otlp_endpoint: otlp_endpoint
end

config :otel_metric_exporter, resource: %{"service.name" => service_name}

if System.get_env("RESTDIS_JSON_LOGGER", "false") in ~w(true 1) do
  config :logger, :default_handler, formatter: {LoggerJSON.Formatters.Basic, metadata: :all}
end

if config_env() == :prod do
  control_plane_cache_dir =
    Path.join(System.get_env("CACHE_DATA_DIR", "/var/lib/restdis/cache"), "control_plane")

  control_plane_cache_ttl_ms =
    String.to_integer(System.get_env("CONTROL_PLANE_CACHE_TTL_MS", "60000"))

  config :restdis_buster,
    tenant_table_config_cache: [
      data_dir: control_plane_cache_dir,
      ttl_ms: control_plane_cache_ttl_ms
    ],
    az: System.get_env("RELEASE_AZ", "local"),
    slot_name: System.get_env("WAL_SLOT_NAME", "restdis_slot"),
    publication_name: System.get_env("WAL_PUBLICATION_NAME", "restdis_pub"),
    replication_connection: [
      url: System.fetch_env!("DATABASE_URL"),
      pool_size: 1
    ]

  topologies =
    case System.get_env("CLUSTER_DNS_QUERY") do
      nil ->
        []

      query ->
        [
          restdis: [
            strategy: Cluster.Strategy.DNSPoll,
            config: [
              query: query,
              node_basename: System.get_env("CLUSTER_NODE_BASENAME", "restdis"),
              polling_interval:
                String.to_integer(System.get_env("CLUSTER_POLL_INTERVAL_MS", "5000"))
            ]
          ]
        ]
    end

  config :restdis_server,
    cache_data_dir: System.get_env("CACHE_DATA_DIR", "/var/lib/restdis/cache")

  config :restdis_replicator,
    origin: RestdisReplicator.Origin.PostgREST,
    page_size: String.to_integer(System.get_env("REPLICATION_PAGE_SIZE", "1000")),
    page_delay_ms: String.to_integer(System.get_env("REPLICATION_PAGE_DELAY_MS", "50")),
    reconcile_stagger_ms:
      String.to_integer(System.get_env("REPLICATION_RECONCILE_STAGGER_MS", "1000"))

  config :restdis_server,
    topologies: topologies,
    resp_port: String.to_integer(System.get_env("RESP_PORT", "6380")),
    resp_listen_ip: System.get_env("RESP_LISTEN_IP", "0.0.0.0"),
    http_port: String.to_integer(System.get_env("HTTP_PORT", "4040")),
    tenant_config_cache: [
      data_dir: control_plane_cache_dir,
      ttl_ms: control_plane_cache_ttl_ms
    ]

  config :restdis_repo, RestdisRepo,
    url: System.fetch_env!("DATABASE_URL"),
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "10"))
end
