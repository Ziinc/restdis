defmodule Restdis.Wal.TailerTest do
  @moduledoc """
  `Tailer` callbacks are pure functions we can invoke directly (no need to
  open a real replication connection for most branches). `stream/1` reads
  the checkpoint through `LsnStore`, which falls back to 0 without a database.
  """
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Restdis.Wal.InstanceConfig
  alias Restdis.Wal.RelationCache
  alias Restdis.Wal.Tailer

  @name :wal_tailer_test

  setup_all do
    InstanceConfig.put(@name, repo: NotARunningRepo, telemetry_prefix: [:wal_tailer_test])
  end

  defp base_state(step \\ :create_slot) do
    %{name: @name, step: step, decode_state: {RelationCache.new(), nil}, last_wal_end: 0}
  end

  describe "init/1" do
    test "returns the initial streaming state" do
      assert {:ok, state} = Tailer.init(@name)
      assert state.name == @name
      assert state.step == :create_slot
      assert state.last_wal_end == 0
    end
  end

  describe "handle_connect/1" do
    test "issues a CREATE_REPLICATION_SLOT query" do
      assert {:query, query, new_state} = Tailer.handle_connect(base_state(:streaming))
      assert query =~ "CREATE_REPLICATION_SLOT"
      assert new_state.step == :create_slot
    end
  end

  describe "handle_result/2" do
    test "starts streaming after a successful CREATE_REPLICATION_SLOT" do
      assert {:stream, query, [], new_state} =
               Tailer.handle_result([:ok_result], base_state())

      assert query =~ "START_REPLICATION"
      assert new_state.step == :streaming
    end

    test "starts streaming when the slot already exists (duplicate_object)" do
      error = %Postgrex.Error{postgres: %{code: :duplicate_object}}

      assert {:stream, query, [], new_state} =
               Tailer.handle_result(error, base_state())

      assert query =~ "START_REPLICATION"
      assert new_state.step == :streaming
    end

    test "ignores any other result" do
      assert {:noreply, state} = Tailer.handle_result(:whatever, base_state(:streaming))
      assert state.step == :streaming
    end
  end

  describe "handle_data/2" do
    test "decodes an XLogData WAL record and dispatches events" do
      wal_end = 42

      # An unrecognized pgoutput message decodes to no events but still exercises the XLogData dispatch path.
      frame = <<?w, 0::64, wal_end::64, 0::64, "?"::binary>>

      assert {:noreply, new_state} = Tailer.handle_data(frame, base_state(:streaming))
      assert new_state.last_wal_end == wal_end
    end

    test "emits its telemetry under the instance's telemetry prefix" do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        ref,
        [:wal_tailer_test, :wal, :received],
        fn event, measurements, _meta, _ -> send(parent, {ref, event, measurements}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(ref) end)

      Tailer.handle_data(<<?w, 0::64, 42::64, 0::64, "?"::binary>>, base_state(:streaming))

      assert_received {^ref, [:wal_tailer_test, :wal, :received], %{bytes: 1, count: 1}}
    end

    test "responds to a primary keepalive requesting a reply" do
      frame = <<?k, 7::64, 0::64, 1::8>>

      assert {:noreply, [status_msg], new_state} =
               Tailer.handle_data(frame, base_state(:streaming))

      assert is_binary(status_msg)
      assert new_state.last_wal_end == 7
    end

    test "responds to a primary keepalive with no reply requested" do
      frame = <<?k, 7::64, 0::64, 0::8>>

      assert {:noreply, [], new_state} = Tailer.handle_data(frame, base_state(:streaming))
      assert new_state.last_wal_end == 7
    end

    test "ignores unrecognized data" do
      state = base_state(:streaming)
      assert {:noreply, ^state} = Tailer.handle_data(<<0>>, state)
    end
  end
end
