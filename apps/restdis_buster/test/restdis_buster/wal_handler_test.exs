defmodule RestdisBuster.WalHandlerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

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

  test "a burst of 1000 events for an unconfigured table makes at most 1 tenant_table_config query" do
    table = "no_such_table_for_fanout_burst"
    TestUtils.clear_table_config()
    test_pid = self()
    handler_id = {__MODULE__, :burst}

    :telemetry.attach(
      handler_id,
      [:restdis_repo, :query],
      fn _event, _measurements, meta, _config ->
        if meta.source == "tenant_table_config" and table in meta.params,
          do: send(test_pid, :table_config_query)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    for _ <- 1..1000 do
      event = %Event{op: :insert, schema: "public", table: table}
      assert WalHandler.handle_event(event) == :defer
    end

    assert_received :table_config_query
    refute_received :table_config_query
  end

  test "handle_info/2 logs and skips an event whose table config lookup raises" do
    TestUtils.clear_table_config()
    previous = Application.fetch_env(:restdis_buster, :repo)
    Application.put_env(:restdis_buster, :repo, RestdisBuster.NoSuchRepo)

    on_exit(fn ->
      case previous do
        {:ok, repo} -> Application.put_env(:restdis_buster, :repo, repo)
        :error -> Application.delete_env(:restdis_buster, :repo)
      end
    end)

    event = %Event{op: :insert, schema: "public", table: "fanout_lookup_error_table"}

    log =
      capture_log(fn ->
        assert WalHandler.handle_event(event) == :defer
      end)

    assert log =~ "fanout_lookup_error_table"
  end
end
