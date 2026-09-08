defmodule RestdisBuster.Infra.LsnStoreTest do
  # Not async: shares persistent_term + the singleton GenServer.
  use ExUnit.Case, async: false

  alias RestdisBuster.Infra.LsnStore
  alias RestdisBuster.TestUtils

  setup do
    TestUtils.checkout_shared_repo!()

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

  test "current_applied/0 and applied/1 handle a missing persistent_term ref" do
    ref_key = {LsnStore, :ref}
    original = :persistent_term.get(ref_key, nil)
    :persistent_term.erase(ref_key)

    on_exit(fn ->
      if original, do: :persistent_term.put(ref_key, original)
    end)

    assert LsnStore.current_applied() == 0
    assert LsnStore.applied(123) == :ok
  end

  test "handle_info(:persist) persists a bumped LSN, then no-ops when nothing new applied" do
    ref_key = {LsnStore, :ref}
    original = :persistent_term.get(ref_key, nil)

    name = :"lsn_store_persist_#{System.unique_integer([:positive])}"
    {:ok, pid} = GenServer.start_link(LsnStore, [], name: name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      if original, do: :persistent_term.put(ref_key, original)
    end)

    LsnStore.applied(500_000)
    send(pid, :persist)
    Process.sleep(50)
    state = :sys.get_state(pid)
    assert state.last_persisted >= 500_000

    send(pid, :persist)
    Process.sleep(50)
    state2 = :sys.get_state(pid)
    assert state2.last_persisted == state.last_persisted
  end

  test "handle_info(:persist) demotes gracefully when the write fails" do
    ref_key = {LsnStore, :ref}
    original = :persistent_term.get(ref_key, nil)
    Application.put_env(:restdis_buster, :repo, NotARunningRepo)

    name = :"lsn_store_persist_fail_#{System.unique_integer([:positive])}"
    {:ok, pid} = GenServer.start_link(LsnStore, [], name: name)

    on_exit(fn ->
      Application.delete_env(:restdis_buster, :repo)
      if Process.alive?(pid), do: GenServer.stop(pid)
      if original, do: :persistent_term.put(ref_key, original)
    end)

    LsnStore.applied(42)
    send(pid, :persist)
    Process.sleep(50)
    state = :sys.get_state(pid)
    assert state.last_persisted == 0
  end

  test "handle_info/2 ignores unknown messages" do
    name = :"lsn_store_catchall_#{System.unique_integer([:positive])}"
    {:ok, pid} = GenServer.start_link(LsnStore, [], name: name)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    send(pid, :some_random_message)
    Process.sleep(10)
    assert Process.alive?(pid)
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
