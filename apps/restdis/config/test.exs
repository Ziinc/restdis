import Config

config :restdis,
  cache_data_dir: System.tmp_dir!() <> "/restdis_test",
  origin: Restdis.Cache.Origin.Stub
