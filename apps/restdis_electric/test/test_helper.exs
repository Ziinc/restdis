ExUnit.start()

test_dir = System.tmp_dir!() <> "/restdis_electric_test"
File.rm_rf!(test_dir)

case Restdis.Cache.Supervisor.start_link(
       data_dir: test_dir,
       origin: Restdis.Cache.Origin.Stub,
       repo: RestdisRepo,
       prefix: "restdis"
     ) do
  {:ok, _pid} -> :ok
  {:error, {:already_started, _pid}} -> :ok
end

case RestdisElectric.Supervisor.start_link([]) do
  {:ok, _pid} -> :ok
  {:error, {:already_started, _pid}} -> :ok
end
