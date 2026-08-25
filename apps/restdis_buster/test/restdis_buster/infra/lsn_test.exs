defmodule RestdisBuster.Infra.LSNTest do
  use ExUnit.Case, async: true

  alias RestdisBuster.Infra.LSN

  test "standby_status byte layout with non-zero applied LSN" do
    bin = LSN.standby_status(100, 50)

    assert <<?r, written::64, flushed::64, applied::64, _clock::64, 0::8>> = bin
    # written = max(stream, applied) + 1
    assert written == 101
    # applied != 0 -> applied + 1 for flushed/applied
    assert flushed == 51
    assert applied == 51
  end

  test "standby_status with applied_lsn = 0 sends 1 for flushed/applied" do
    bin = LSN.standby_status(0, 0)

    assert <<?r, written::64, flushed::64, applied::64, _clock::64, 0::8>> = bin
    assert written == 1
    assert flushed == 1
    assert applied == 1
  end

  test "standby_status: applied beyond stream end advances written too" do
    bin = LSN.standby_status(10, 500)
    assert <<?r, written::64, flushed::64, applied::64, _clock::64, 0::8>> = bin
    assert written == 501
    assert flushed == 501
    assert applied == 501
  end

  test "standby_status total byte size is 34" do
    assert byte_size(LSN.standby_status(0, 0)) == 1 + 8 + 8 + 8 + 8 + 1
  end
end
