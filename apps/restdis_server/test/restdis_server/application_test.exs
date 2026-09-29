defmodule RestdisServer.ApplicationTest do
  use ExUnit.Case, async: false

  # Reverse of the release boot order in the umbrella mix.exs, limited to this app's dependency closure.
  @stop_order [:restdis_server, :restdis_replicator, :restdis_electric, :restdis, :restdis_repo]

  setup do
    on_exit(fn -> {:ok, _apps} = Application.ensure_all_started(:restdis_server) end)
  end

  test "Restdis.Cache is mounted once, by :restdis_replicator" do
    cache_pid = Process.whereis(Restdis.Cache)
    assert is_pid(cache_pid)

    owners =
      for sup <- [RestdisReplicator.Supervisor, RestdisServer.Supervisor],
          {_id, ^cache_pid, _type, _mods} <- Supervisor.which_children(sup),
          do: sup

    assert owners == [RestdisReplicator.Supervisor]
  end

  test "stopping the applications in reverse release order completes within 10s" do
    task = Task.async(fn -> Enum.map(@stop_order, &Application.stop/1) end)

    assert {:ok, results} = Task.yield(task, 10_000) || Task.shutdown(task, :brutal_kill)
    assert Enum.all?(results, &(&1 == :ok))
    refute Process.whereis(Restdis.Cache)
  end
end
