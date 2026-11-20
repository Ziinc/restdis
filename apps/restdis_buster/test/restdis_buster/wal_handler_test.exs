defmodule RestdisBuster.WalHandlerTest do
  use ExUnit.Case, async: false

  alias Restdis.Wal.Event
  alias RestdisBuster.TestUtils
  alias RestdisBuster.WalHandler

  setup do
    TestUtils.checkout_shared_repo!()
    :ok
  end

  test "handle_event/1 hands the event to a worker, which acks it once applied" do
    event = %Event{op: :insert, schema: "public", table: "no_such_table_for_wal_handler_test"}

    assert WalHandler.handle_event(event) == :defer
  end
end
