ExUnit.start()

{:ok, _pid} = Restdis.Cache.Supervisor.start_link([])

test_dir =
  Application.get_env(
    :restdis,
    :cache_data_dir,
    System.tmp_dir!() <> "/restdis_test"
  )

File.rm_rf!(test_dir)
