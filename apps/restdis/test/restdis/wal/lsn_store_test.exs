defmodule Restdis.Wal.LsnStoreTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Restdis.TestRepo
  alias Restdis.Wal.InstanceConfig
  alias Restdis.Wal.LsnStore

  @prefix "wal_lsn_test"

  defmodule CheckpointMigration do
    use Ecto.Migration

    def up, do: Restdis.Migration.up(version: 1, prefix: "wal_lsn_test")
    def down, do: Restdis.Migration.down(version: 1, prefix: "wal_lsn_test")
  end

  defp start_store(name, repo) do
    :ok = InstanceConfig.put(name, repo: repo, prefix: @prefix, slot_name: "slot_#{name}")
    start_supervised!({LsnStore, name: name}, id: name)
  end

  defp unique_name, do: :"wal_lsn_#{System.unique_integer([:positive])}"

  test "applied/2 only moves the applied LSN forward" do
    name = unique_name()
    start_store(name, NotARunningRepo)

    :ok = LsnStore.applied(name, 100)
    :ok = LsnStore.applied(name, 90)
    assert LsnStore.current_applied(name) == 100

    :ok = LsnStore.applied(name, 1_000_000)
    assert LsnStore.current_applied(name) == 1_000_000
  end

  test "applied/2 with a nil LSN is a no-op" do
    name = unique_name()
    start_store(name, NotARunningRepo)

    assert LsnStore.applied(name, nil) == :ok
    assert LsnStore.current_applied(name) == 0
  end

  test "an instance with no store running reports 0 and ignores applied LSNs" do
    assert LsnStore.applied(:no_such_wal, 123) == :ok
    assert LsnStore.current_applied(:no_such_wal) == 0
  end

  test "two instances track their applied LSNs independently" do
    a = unique_name()
    b = unique_name()
    start_store(a, NotARunningRepo)
    start_store(b, NotARunningRepo)

    :ok = LsnStore.applied(a, 500)

    assert LsnStore.current_applied(a) == 500
    assert LsnStore.current_applied(b) == 0
  end

  test "a failed checkpoint write keeps the last persisted LSN" do
    name = unique_name()
    pid = start_store(name, NotARunningRepo)

    :ok = LsnStore.applied(name, 42)
    send(pid, :persist)

    assert :sys.get_state(pid).last_persisted == 0
    assert LsnStore.persisted(name) == 0
  end

  test "a temporary instance's store tracks applied LSNs without a checkpoint" do
    name = unique_name()
    :ok = InstanceConfig.put(name, temporary: true, slot_name: "slot_#{name}")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        pid = start_supervised!({LsnStore, name: name}, id: name)
        :ok = LsnStore.applied(name, 42)
        send(pid, :persist)
        :sys.get_state(pid)
      end)

    refute log =~ "LsnStore"
    assert LsnStore.current_applied(name) == 42
    assert LsnStore.persisted(name) == 0
  end

  test "ignores unknown messages" do
    name = unique_name()
    pid = start_store(name, NotARunningRepo)

    send(pid, :some_random_message)

    assert :sys.get_state(pid).last_persisted == 0
  end

  @tag :db
  test "checkpoints to <prefix>.wal_checkpoint and a restarted store resumes from it" do
    version = System.unique_integer([:positive, :monotonic])
    Ecto.Migrator.up(TestRepo, version, CheckpointMigration, log: false)
    on_exit(fn -> TestRepo.query!(~s(DROP SCHEMA IF EXISTS "#{@prefix}" CASCADE)) end)

    name = unique_name()
    pid = start_store(name, TestRepo)

    :ok = LsnStore.applied(name, 500_000)
    send(pid, :persist)
    assert :sys.get_state(pid).last_persisted == 500_000

    assert %{rows: [[500_000]]} =
             TestRepo.query!(
               ~s(SELECT lsn FROM "#{@prefix}".wal_checkpoint WHERE slot_name = $1),
               ["slot_#{name}"]
             )

    assert LsnStore.persisted(name) == 500_000

    stop_supervised!(name)
    start_store(name, TestRepo)

    assert LsnStore.current_applied(name) == 500_000
  end
end
