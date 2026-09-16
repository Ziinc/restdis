import Config

config :logger, level: :info

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :tenant_id, :az]

config :restdis_server, tenant_store: RestdisServer.TenantStore.Repo

config :restdis_repo, RestdisRepo, start_apps_before_migration: [:ssl]
