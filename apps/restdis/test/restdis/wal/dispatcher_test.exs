defmodule Restdis.Wal.DispatcherTest do
  use ExUnit.Case, async: false

  alias Restdis.Cache.TestUtils
  alias Restdis.Wal.Dispatcher
  alias Restdis.Wal.Event
  alias Restdis.Wal.InstanceConfig

  defmodule LocalHandler do
    @behaviour Restdis.Wal.Handler

    @impl Restdis.Wal.Handler
    def handle_event(event) do
      send(:wal_dispatch_local_test, {:handled, event})
      :ok
    end
  end

  setup_all do
    TestUtils.start_syn!()
  end

  setup do
    name = :"wal_dispatch_#{System.unique_integer([:positive])}"
    :ok = InstanceConfig.put(name, repo: NotARunningRepo, az: "test")
    :syn.join(:wal_fanout, {name, "test"}, self())
    on_exit(fn -> :syn.leave(:wal_fanout, {name, "test"}, self()) end)
    {:ok, name: name}
  end

  defp event(table), do: %Event{op: :insert, schema: "public", table: table, new_row: %{}}

  test "dispatch/2 publishes the event to the instance's group for the current AZ", %{name: name} do
    event = event("products")

    assert Dispatcher.dispatch(name, event) == :ok
    assert_receive {:wal_event, ^event}, 500
  end

  test "multiple subscribers in the same AZ each receive the event", %{name: name} do
    parent = self()

    {:ok, second} =
      Task.start(fn ->
        :syn.join(:wal_fanout, {name, "test"}, self())
        send(parent, :joined)

        receive do
          {:wal_event, event} -> send(parent, {:second_got, event})
        after
          500 -> send(parent, :second_timeout)
        end
      end)

    assert_receive :joined, 200

    event = event("items")
    Dispatcher.dispatch(name, event)

    assert_receive {:wal_event, ^event}, 500
    assert_receive {:second_got, ^event}, 500

    Process.exit(second, :kill)
  end

  test "dispatch/2 fans out to every known AZ of the instance, not just its own", %{name: name} do
    parent = self()

    {:ok, remote} =
      Task.start(fn ->
        :syn.join(:wal_fanout, {name, "other-az"}, self())
        send(parent, :joined)

        receive do
          {:wal_event, event} -> send(parent, {:remote_got, event})
        after
          1000 -> send(parent, :remote_timeout)
        end
      end)

    assert_receive :joined, 200

    event = event("multi_az")
    Dispatcher.dispatch(name, event)

    assert_receive {:wal_event, ^event}, 500
    assert_receive {:remote_got, ^event}, 500

    :syn.leave(:wal_fanout, {name, "other-az"}, remote)
    Process.exit(remote, :kill)
  end

  test "dispatch/2 does not reach another instance's subscribers" do
    other = :"wal_dispatch_other_#{System.unique_integer([:positive])}"
    :ok = InstanceConfig.put(other, repo: NotARunningRepo, az: "test")

    event = event("isolated")
    Dispatcher.dispatch(other, event)

    refute_receive {:wal_event, ^event}, 100
  end

  test "dispatch/2 falls back to the instance's own AZ when it has no fanout groups" do
    lonely = :"wal_dispatch_lonely_#{System.unique_integer([:positive])}"
    :ok = InstanceConfig.put(lonely, repo: NotARunningRepo, az: "test")

    assert Dispatcher.dispatch(lonely, event("fallback_table")) == :ok
  end

  test "dispatch/2 hands events straight to the handler under the :local topology" do
    Process.register(self(), :wal_dispatch_local_test)
    local = :"wal_dispatch_local_#{System.unique_integer([:positive])}"

    :ok =
      InstanceConfig.put(local, repo: NotARunningRepo, topology: :local, handler: LocalHandler)

    event = event("local_table")
    assert Dispatcher.dispatch(local, event) == :ok

    assert_received {:handled, ^event}
    refute_received {:wal_event, _}
  end
end
