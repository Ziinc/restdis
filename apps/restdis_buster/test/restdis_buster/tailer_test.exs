defmodule RestdisBuster.TailerTest do
  @moduledoc """
  `Tailer` callbacks are pure functions we can invoke directly (no need to
  open a real replication connection for most branches). `stream/1`
  touches the DB via `SlotConfig`/`LsnStore`, both of which are available
  in the test environment.
  """
  use ExUnit.Case, async: true

  alias RestdisBuster.Tailer
  alias RestdisBuster.WAL.RelationCache

  defp base_state(step \\ :create_slot) do
    %{step: step, decode_state: {RelationCache.new(), nil}, last_wal_end: 0}
  end

  describe "init/1" do
    test "returns the initial streaming state" do
      assert {:ok, state} = Tailer.init(:ok)
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
