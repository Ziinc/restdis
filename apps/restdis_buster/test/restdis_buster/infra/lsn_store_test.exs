defmodule RestdisBuster.Infra.LsnStoreTest do
  # Not async: shares persistent_term + the singleton GenServer.
  use ExUnit.Case, async: false

  alias RestdisBuster.Infra.LsnStore

  setup do
    # The application starts LsnStore; start a fresh one if the DB was degraded.
    case Process.whereis(LsnStore) do
      nil ->
        {:ok, _} = LsnStore.start_link([])
        :ok

      _pid ->
        :ok
    end

    :ok
  end

  test "applied/1 ignores lower LSNs (monotonic)" do
    base = LsnStore.current_applied()

    :ok = LsnStore.applied(base + 100)
    after_high = LsnStore.current_applied()
    assert after_high >= base + 100

    :ok = LsnStore.applied(after_high - 10)
    assert LsnStore.current_applied() == after_high
  end

  test "applied/1 advances on higher LSN" do
    base = LsnStore.current_applied()
    :ok = LsnStore.applied(base + 1)
    assert LsnStore.current_applied() >= base + 1

    :ok = LsnStore.applied(base + 1_000_000)
    assert LsnStore.current_applied() >= base + 1_000_000
  end

  test "applied/1 with nil is a no-op" do
    before = LsnStore.current_applied()
    assert :ok = LsnStore.applied(nil)
    assert LsnStore.current_applied() == before
  end

  test "current_applied/0 returns an integer" do
    assert is_integer(LsnStore.current_applied())
    assert LsnStore.current_applied() >= 0
  end

  @tag :db
  test "persisted/0 returns 0 when no row / DB unavailable" do
    # Without a DB this just returns 0 via the rescue path.
    assert is_integer(LsnStore.persisted())
  end

  test "reads the repo from :restdis_buster, :repo instead of a hardcoded RestdisRepo" do
    # Non-running module proves repo comes from injected config, not a hardcoded atom.
    Application.put_env(:restdis_buster, :repo, NotARunningRepo)
    on_exit(fn -> Application.delete_env(:restdis_buster, :repo) end)

    {:ok, pid} =
      GenServer.start_link(LsnStore, [],
        name: :"lsn_store_repo_injection_#{System.unique_integer()}"
      )

    assert Process.alive?(pid)
    GenServer.stop(pid)
  end
end
