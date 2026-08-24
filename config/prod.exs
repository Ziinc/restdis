import Config

config :logger, level: :info

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :tenant_id, :az]

config :supa_cacher_cache, origin: SupaCacherCache.Origin.PostgREST

config :supa_cacher_server, tenant_store: SupaCacherServer.TenantStore.Repo

config :supa_cacher_repo, SupaCacherRepo, start_apps_before_migration: [:ssl]
