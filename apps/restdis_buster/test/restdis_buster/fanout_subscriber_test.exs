defmodule RestdisBuster.FanoutSubscriberTest do
  use ExUnit.Case, async: false

  alias RestdisBuster.FanoutSubscriber
  alias RestdisBuster.WAL.Event

  test "init/1 joins the :wal_fanout group for this node's AZ" do
    az = Application.get_env(:restdis_buster, :az, "test")
    assert {:ok, %{az: ^az}} = FanoutSubscriber.init([])

    # `init/1` was invoked directly (not via `start_link`), so `self()` is
    # this test process; leave the group it just joined.
    on_exit(fn -> :syn.leave(:wal_fanout, {:az, az}, self()) end)
  end

  test "handle_info/2 dispatches a :wal_event to the worker supervisor" do
    event = %Event{op: :insert, schema: "public", table: "no_such_table_for_fanout_test"}
    state = %{az: "test"}

    assert {:noreply, ^state} = FanoutSubscriber.handle_info({:wal_event, event}, state)
  end

  test "handle_info/2 ignores unrelated messages" do
    state = %{az: "test"}
    assert {:noreply, ^state} = FanoutSubscriber.handle_info(:something_else, state)
  end
end
