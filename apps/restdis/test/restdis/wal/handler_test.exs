defmodule Restdis.Wal.HandlerTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Restdis.Wal.Event
  alias Restdis.Wal.Handler
  alias Restdis.Wal.InstanceConfig
  alias Restdis.Wal.LsnStore

  defmodule AckingHandler do
    @behaviour Restdis.Wal.Handler

    @impl Restdis.Wal.Handler
    def handle_event(event) do
      send(:wal_handler_test, {:handled, event})
      :ok
    end
  end

  defmodule DeferringHandler do
    @behaviour Restdis.Wal.Handler

    @impl Restdis.Wal.Handler
    def handle_event(_event), do: :defer
  end

  defp start_instance(handler) do
    name = :"wal_handler_#{System.unique_integer([:positive])}"
    :ok = InstanceConfig.put(name, repo: NotARunningRepo, handler: handler)
    start_supervised!({LsnStore, name: name}, id: name)
    name
  end

  setup do
    Process.register(self(), :wal_handler_test)
    :ok
  end

  test "dispatch/2 hands the event to the instance's handler and acks its LSN" do
    name = start_instance(AckingHandler)
    event = %Event{op: :insert, schema: "public", table: "t", lsn: 700}

    assert Handler.dispatch(name, event) == :ok

    assert_received {:handled, ^event}
    assert LsnStore.current_applied(name) == 700
  end

  test "dispatch/2 leaves the LSN to the host when the handler defers" do
    name = start_instance(DeferringHandler)

    assert Handler.dispatch(name, %Event{op: :insert, lsn: 700}) == :ok

    assert LsnStore.current_applied(name) == 0
  end
end
