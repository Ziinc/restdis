import Config

config :supa_cacher_cache,
  cache_data_dir: "./cache_data",
  origin: SupaCacherCache.Origin.Stub,
  tenant_config_lookup: {SupaCacherServer.TenantConfig, :lookup_by_tenant_id, []}

config :supa_cacher_server,
  resp_port: 6380,
  http_port: 4040,
  tenant_store: SupaCacherServer.TenantStore.Repo

config :supa_cacher_repo,
  ecto_repos: [SupaCacherRepo]

import_config "#{config_env()}.exs"
