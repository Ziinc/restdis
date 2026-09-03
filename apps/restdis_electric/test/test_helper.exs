ExUnit.start()

test_dir = System.tmp_dir!() <> "/restdis_electric_test"
File.rm_rf!(test_dir)
Application.put_env(:restdis, :cache_data_dir, test_dir)

case Restdis.Cache.Supervisor.start_link([]) do
  {:ok, _pid} -> :ok
  {:error, {:already_started, _pid}} -> :ok
end

case RestdisElectric.Supervisor.start_link([]) do
  {:ok, _pid} -> :ok
  {:error, {:already_started, _pid}} -> :ok
end
