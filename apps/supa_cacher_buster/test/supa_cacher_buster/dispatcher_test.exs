defmodule SupaCacherBuster.DispatcherTest do
  use ExUnit.Case, async: false

  alias SupaCacherBuster.Dispatcher
  alias SupaCacherBuster.TestUtils

  setup do
    # Join the test AZ group before each test
    az = Application.get_env(:supa_cacher_buster, :az, "test")
    :syn.join(:wal_fanout, {:az, az}, self())
    on_exit(fn -> :syn.leave(:wal_fanout, {:az, az}, self()) end)
    {:ok, az: az}
  end

  test "dispatch/1 publishes event to :wal_fanout group for current AZ" do
    event = TestUtils.insert_event("products", "public", %{"id" => "1"})
    Dispatcher.dispatch(event)

    assert_receive {:wal_event, ^event}, 200
  end

  test "dispatch/1 returns :ok" do
    event = TestUtils.insert_event("orders")
    assert :ok = Dispatcher.dispatch(event)
  end

  test "multiple subscribers in the same AZ each receive the event" do
    az = Application.get_env(:supa_cacher_buster, :az, "test")

    # Spawn a second subscriber
    parent = self()
    {:ok, second} = Task.start(fn ->
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

    assert_receive {:wal_event, ^event}, 200
    assert_receive {:second_got, ^event}, 200

    Process.exit(second, :kill)
  end
end
