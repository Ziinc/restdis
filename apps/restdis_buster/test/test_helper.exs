ExUnit.start(exclude: [:integration])

# Another app's suite in the same VM run may have torn down Restdis.Cache.Supervisor; ensure it's up.
case Restdis.Cache.Supervisor.start_link([]) do
  {:ok, _pid} -> :ok
  {:error, {:already_started, _pid}} -> :ok
end
