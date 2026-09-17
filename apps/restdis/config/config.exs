import Config

config :restdis,
  hot_cache_transport: Restdis.Cache.HotCache.Transport.Distribution

if config_env() == :test, do: import_config("test.exs")
