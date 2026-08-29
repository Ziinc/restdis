case Restdis.Cache.Supervisor.start_link([]) do
  {:ok, _pid} -> :ok
  {:error, {:already_started, _pid}} -> :ok
end

ExUnit.start(exclude: [:integration])
