defmodule RestdisBuster.DispatcherTest do
  use ExUnit.Case, async: false

  alias RestdisBuster.Dispatcher
  alias RestdisBuster.TestUtils

  import RestdisBuster.TestUtils, only: [assert_receive_eventually: 1]

  setup do
    # Join the test AZ group before each test
    az = Application.get_env(:restdis_buster, :az, "test")
    :syn.join(:wal_fanout, {:az, az}, self())
    on_exit(fn -> :syn.leave(:wal_fanout, {:az, az}, self()) end)
    {:ok, az: az}
  end

  test "dispatch/1 publishes event to :wal_fanout group for current AZ" do
    event = TestUtils.insert_event("products", "public", %{"id" => "1"})
    Dispatcher.dispatch(event)

    assert_receive_eventually({:wal_event, ^event})
  end

  test "dispatch/1 returns :ok" do
    event = TestUtils.insert_event("orders")
    assert :ok = Dispatcher.dispatch(event)
  end

  test "multiple subscribers in the same AZ each receive the event" do
    az = Application.get_env(:restdis_buster, :az, "test")

    # Spawn a second subscriber
    parent = self()

    {:ok, second} =
      Task.start(fn ->
        :syn.join(:wal_fanout, {:az, az}, self())

        receive do
          {:wal_event, event} -> send(parent, {:second_got, event})
        after
          500 -> send(parent, :second_timeout)
        end
      end)

    # Give the Task time to join
    Process.sleep(50)

    event = TestUtils.insert_event("items")
    Dispatcher.dispatch(event)

    assert_receive_eventually({:wal_event, ^event})
    assert_receive_eventually({:second_got, ^event})

    Process.exit(second, :kill)
  end

  test "dispatch/1 fans out to all known AZ groups, not just the dispatching node's own AZ" do
    other_az = "other-az-#{System.unique_integer([:positive])}"
    parent = self()

    {:ok, remote} =
      Task.start(fn ->
        :syn.join(:wal_fanout, {:az, other_az}, self())
        send(parent, :joined)

        receive do
          {:wal_event, event} -> send(parent, {:remote_got, event})
        after
          1000 -> send(parent, :remote_timeout)
        end
      end)

    assert_receive :joined, 200

    event = TestUtils.insert_event("multi_az")
    Dispatcher.dispatch(event)

    assert_receive_eventually({:wal_event, ^event})
    assert_receive_eventually({:remote_got, ^event})

    :syn.leave(:wal_fanout, {:az, other_az}, remote)
    Process.exit(remote, :kill)
  end

  test "dispatch/1 falls back to the local AZ when no fanout groups exist" do
    az = Application.get_env(:restdis_buster, :az, "test")

    # Leave both this test's `self()` and the real `FanoutSubscriber` (both members of the `az` group), so `:wal_fanout` has zero groups and `known_azs/0` falls back to `SlotConfig.az()`; rejoin both afterwards.
    real_subscriber = Process.whereis(RestdisBuster.FanoutSubscriber)
    :syn.leave(:wal_fanout, {:az, az}, self())
    if real_subscriber, do: :syn.leave(:wal_fanout, {:az, az}, real_subscriber)

    on_exit(fn ->
      :syn.join(:wal_fanout, {:az, az}, self())
      if real_subscriber, do: :syn.join(:wal_fanout, {:az, az}, real_subscriber)
    end)

    assert :syn.group_names(:wal_fanout) == []

    event = TestUtils.insert_event("fallback_table")
    assert :ok = Dispatcher.dispatch(event)
  end
end
