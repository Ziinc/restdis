import Config

config :restdis,
  cache_data_dir: "./cache_data",
  origin: Restdis.Cache.Origin.Stub,
  replication_transport: Restdis.Cache.Replication.Transport.Distribution

if config_env() == :test, do: import_config("test.exs")
