ExUnit.start()

test_dir =
  Application.get_env(
    :supa_cacher_cache,
    :cache_data_dir,
    System.tmp_dir!() <> "/supacacher_test"
  )

File.rm_rf!(test_dir)
