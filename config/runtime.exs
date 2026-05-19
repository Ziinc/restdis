import Config

if config_env() == :prod do
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
