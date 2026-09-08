ExUnit.start(exclude: [:integration])

# When the whole umbrella runs `mix test` from the root in a single VM,
# another app's suite may have already started and later torn down
# Restdis.Cache.Supervisor, invalidating the ETS table refs our cache
# code holds. Ensure it (and its ETS tables) are up before our own tests
# run, regardless of what happened earlier in the shared VM.
case Restdis.Cache.Supervisor.start_link([]) do
  {:ok, _pid} -> :ok
  {:error, {:already_started, _pid}} -> :ok
end
