ExUnit.start()

test_dir = System.tmp_dir!() <> "/restdis_electric_test"
File.rm_rf!(test_dir)
Application.put_env(:restdis, :cache_data_dir, test_dir)

{:ok, _pid} = Restdis.Cache.Supervisor.start_link([])
{:ok, _pid} = RestdisElectric.Supervisor.start_link([])
