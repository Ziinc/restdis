import Config

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

  config :supa_cacher_server,
    resp_port: String.to_integer(System.get_env("RESP_PORT", "6380")),
    http_port: String.to_integer(System.get_env("HTTP_PORT", "4040")),
    tenant_store: SupaCacherServer.TenantStore.Repo

  config :supa_cacher_repo, SupaCacherRepo,
    url: System.fetch_env!("DATABASE_URL"),
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "10"))
end
