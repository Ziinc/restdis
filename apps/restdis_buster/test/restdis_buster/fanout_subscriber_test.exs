defmodule RestdisBuster.FanoutSubscriberTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias RestdisBuster.FanoutSubscriber
  alias RestdisBuster.TestUtils
  alias RestdisBuster.WAL.Event

  setup do
    TestUtils.checkout_shared_repo!()
    :ok
  end

  test "init/1 joins the :wal_fanout group for this node's AZ" do
    az = Application.get_env(:restdis_buster, :az, "test")
    assert {:ok, %{az: ^az}} = FanoutSubscriber.init([])

    # `init/1` ran directly (not via `start_link`), so `self()` is this test process; leave the joined group.
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

    state = %{az: "test"}

    for _ <- 1..1000 do
      event = %Event{op: :insert, schema: "public", table: table}
      assert {:noreply, ^state} = FanoutSubscriber.handle_info({:wal_event, event}, state)
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
    state = %{az: "test"}

    log =
      capture_log(fn ->
        assert {:noreply, ^state} = FanoutSubscriber.handle_info({:wal_event, event}, state)
      end)

    assert log =~ "fanout_lookup_error_table"
  end
end
