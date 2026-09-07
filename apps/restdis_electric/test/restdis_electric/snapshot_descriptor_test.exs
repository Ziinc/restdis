defmodule RestdisElectric.SnapshotDescriptorTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias RestdisElectric.SnapshotDescriptor

  describe "parse/1" do
    test "parses xmin, xmax and an xip_list" do
      assert {:ok, %{xmin: 10, xmax: 20, xip_list: [12, 15]}} =
               SnapshotDescriptor.parse("10:20:12,15")
    end

    test "parses an empty xip_list" do
      assert {:ok, %{xmin: 10, xmax: 10, xip_list: []}} = SnapshotDescriptor.parse("10:10:")
    end

    test "rejects malformed text" do
      assert :error = SnapshotDescriptor.parse("not-a-snapshot")
    end

    test "rejects a non-binary value" do
      assert :error = SnapshotDescriptor.parse(123)
      assert :error = SnapshotDescriptor.parse(nil)
    end

    test "rejects an xip_list with a non-integer element" do
      assert :error = SnapshotDescriptor.parse("10:20:12,abc")
    end

    test "rejects a non-integer xmin or xmax" do
      assert :error = SnapshotDescriptor.parse("abc:20:")
      assert :error = SnapshotDescriptor.parse("10:abc:")
    end
  end

  describe "visible?/2" do
    test "a transaction below xmin is visible (already committed)" do
      descriptor = %{xmin: 10, xmax: 20, xip_list: []}
      assert SnapshotDescriptor.visible?(descriptor, 5)
    end

    test "a transaction at or above xmax is not visible (not yet started)" do
      descriptor = %{xmin: 10, xmax: 20, xip_list: []}
      refute SnapshotDescriptor.visible?(descriptor, 20)
      refute SnapshotDescriptor.visible?(descriptor, 25)
    end

    test "a transaction between xmin and xmax, in xip_list, is not visible (in progress)" do
      descriptor = %{xmin: 10, xmax: 20, xip_list: [14]}
      refute SnapshotDescriptor.visible?(descriptor, 14)
    end

    test "a transaction between xmin and xmax, not in xip_list, is visible (committed)" do
      descriptor = %{xmin: 10, xmax: 20, xip_list: [14]}
      assert SnapshotDescriptor.visible?(descriptor, 15)
    end
  end

  describe "cursor decisions" do
    test "a visible xid is skipped, cursor keeps comparing" do
      descriptor = %{xmin: 10, xmax: 20, xip_list: [14]}
      cursor = SnapshotDescriptor.new_cursor(descriptor)
      assert {:skip, cursor} = SnapshotDescriptor.decide(cursor, 5)
      assert {:skip, _cursor} = SnapshotDescriptor.decide(cursor, 15)
    end

    test "an xid at or after xmax is logged and latches the cursor into always-log" do
      descriptor = %{xmin: 10, xmax: 20, xip_list: []}
      cursor = SnapshotDescriptor.new_cursor(descriptor)
      assert {:log, cursor} = SnapshotDescriptor.decide(cursor, 20)
      assert SnapshotDescriptor.always_log?(cursor)
    end

    test "an in-progress xid is logged but does not latch the cursor" do
      descriptor = %{xmin: 10, xmax: 20, xip_list: [14]}
      cursor = SnapshotDescriptor.new_cursor(descriptor)
      assert {:log, cursor} = SnapshotDescriptor.decide(cursor, 14)
      refute SnapshotDescriptor.always_log?(cursor)
    end

    test "once latched, every later xid is logged without comparison, avoiding 32-bit wraparound" do
      descriptor = %{xmin: 10, xmax: 20, xip_list: []}
      cursor = SnapshotDescriptor.new_cursor(descriptor)
      {:log, cursor} = SnapshotDescriptor.decide(cursor, 20)
      # A wrapped-around xid that would otherwise look "below xmin" is still logged.
      assert {:log, cursor} = SnapshotDescriptor.decide(cursor, 3)
      assert {:log, _cursor} = SnapshotDescriptor.decide(cursor, 1)
    end

    property "once latched, decide/2 always returns :log regardless of xid" do
      check all(
              xmin <- integer(1..1000),
              span <- integer(1..1000),
              probe <- integer(0..4_294_967_295)
            ) do
        xmax = xmin + span
        descriptor = %{xmin: xmin, xmax: xmax, xip_list: []}
        cursor = SnapshotDescriptor.new_cursor(descriptor)
        {:log, latched} = SnapshotDescriptor.decide(cursor, xmax)
        assert {:log, ^latched} = SnapshotDescriptor.decide(latched, probe)
      end
    end

    property "before latching, a visible xid is always skipped and an invisible one is always logged" do
      check all(
              xmin <- integer(1..1000),
              span <- integer(1..1000),
              offset <- integer(0..2000)
            ) do
        xmax = xmin + span
        xid = xmin + offset
        descriptor = %{xmin: xmin, xmax: xmax, xip_list: []}
        cursor = SnapshotDescriptor.new_cursor(descriptor)
        {decision, _cursor} = SnapshotDescriptor.decide(cursor, xid)

        if xid < xmax do
          assert decision == :skip
        else
          assert decision == :log
        end
      end
    end
  end

  describe "to_string/1" do
    test "round-trips through parse/1" do
      text = "10:20:12,15"
      assert {:ok, descriptor} = SnapshotDescriptor.parse(text)
      assert SnapshotDescriptor.to_string(descriptor) == text
    end

    test "an empty xip_list encodes with a trailing colon" do
      assert SnapshotDescriptor.to_string(%{xmin: 10, xmax: 10, xip_list: []}) == "10:10:"
    end
  end
end
