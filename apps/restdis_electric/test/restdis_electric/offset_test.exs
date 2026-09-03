defmodule RestdisElectric.OffsetTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias RestdisElectric.Offset

  describe "decode/1 and encode/1" do
    test "-1 decodes to beginning" do
      assert {:ok, :beginning} = Offset.decode("-1")
      assert Offset.encode(:beginning) == "-1"
    end

    test "0_inf decodes to the snapshot end" do
      assert {:ok, {0, :inf}} = Offset.decode("0_inf")
      assert Offset.encode({0, :inf}) == "0_inf"
    end

    test "now decodes to :now" do
      assert {:ok, :now} = Offset.decode("now")
      assert Offset.encode(:now) == "now"
    end

    test "{lsn}_{op_offset} decodes to a position" do
      assert {:ok, {123, 4}} = Offset.decode("123_4")
      assert Offset.encode({123, 4}) == "123_4"
    end

    test "rejects malformed input" do
      assert :error = Offset.decode(nil)
      assert :error = Offset.decode("")
      assert :error = Offset.decode("abc")
      assert :error = Offset.decode("-5_3")
      assert :error = Offset.decode("5_-3")
      assert :error = Offset.decode("5_")
    end
  end

  describe "ordering" do
    test "beginning sorts before every position" do
      assert Offset.before?(:beginning, {0, 0})
      assert Offset.before?(:beginning, {0, :inf})
    end

    test "op offsets sort before inf at the same lsn" do
      assert Offset.before?({0, 5}, {0, :inf})
    end

    test "a later lsn sorts after an earlier one regardless of op offset" do
      assert Offset.before?({0, :inf}, {1, 0})
    end

    test "now sorts after every position" do
      assert Offset.before?({999, :inf}, :now)
    end

    property "encode/decode round-trips every generated position" do
      check all(
              lsn <- StreamData.integer(0..1_000_000),
              op <- StreamData.integer(0..1_000_000)
            ) do
        wire = Offset.encode({lsn, op})
        assert {:ok, {^lsn, ^op}} = Offset.decode(wire)
      end
    end

    property "before?/2 agrees with encoding order for same-lsn positions" do
      check all(
              lsn <- StreamData.integer(0..1000),
              a <- StreamData.integer(0..1000),
              b <- StreamData.integer(0..1000)
            ) do
        if a < b do
          assert Offset.before?({lsn, a}, {lsn, b})
        end
      end
    end
  end
end
