defmodule Restdis.Wal.FanoutSubscriberTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Restdis.Cache.TestUtils
  alias Restdis.Wal.Event
  alias Restdis.Wal.FanoutSubscriber
  alias Restdis.Wal.InstanceConfig
  alias Restdis.Wal.LsnStore

  defmodule ForwardingHandler do
    @behaviour Restdis.Wal.Handler

    @impl Restdis.Wal.Handler
    def handle_event(event) do
      send(:wal_fanout_test, {:handled, event})
      :ok
    end
  end

  setup_all do
    TestUtils.start_syn!()
  end

  setup do
    name = :"wal_fanout_#{System.unique_integer([:positive])}"
    :ok = InstanceConfig.put(name, repo: NotARunningRepo, az: "test", handler: ForwardingHandler)
    start_supervised!({LsnStore, name: name}, id: {LsnStore, name})
    Process.register(self(), :wal_fanout_test)
    {:ok, name: name}
  end

  test "joins the instance's :wal_fanout group for its AZ", %{name: name} do
    pid = start_supervised!({FanoutSubscriber, name: name})

    assert {pid, :undefined} in :syn.members(:wal_fanout, {name, "test"})
  end

  test "hands each :wal_event to the instance's handler and acks it", %{name: name} do
    pid = start_supervised!({FanoutSubscriber, name: name})
    event = %Event{op: :insert, schema: "public", table: "t", lsn: 900}

    send(pid, {:wal_event, event})

    assert_receive {:handled, ^event}, 500
    assert LsnStore.current_applied(name) == 900
  end

  test "ignores unrelated messages", %{name: name} do
    pid = start_supervised!({FanoutSubscriber, name: name})

    send(pid, :something_else)

    assert :sys.get_state(pid) == %{name: name, az: "test"}
  end
end
