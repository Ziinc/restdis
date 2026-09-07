defmodule RestdisServer.RESP.EncoderTest do
  use ExUnit.Case, async: true

  alias RestdisServer.RESP.Encoder

  test "simple_string/1 wraps the string in a RESP simple string" do
    assert IO.iodata_to_binary(Encoder.simple_string("OK")) == "+OK\r\n"
  end

  test "error/1 wraps the message in a RESP error" do
    assert IO.iodata_to_binary(Encoder.error("boom")) == "-boom\r\n"
  end

  test "integer/1 wraps the number in a RESP integer" do
    assert IO.iodata_to_binary(Encoder.integer(42)) == ":42\r\n"
  end

  test "bulk_string/1 encodes nil as the null bulk string" do
    assert IO.iodata_to_binary(Encoder.bulk_string(nil)) == "$-1\r\n"
  end

  test "bulk_string/1 encodes a binary with its byte length" do
    assert IO.iodata_to_binary(Encoder.bulk_string("hello")) == "$5\r\nhello\r\n"
  end

  test "array/1 encodes a mix of nils, integers and binaries" do
    encoded = IO.iodata_to_binary(Encoder.array([nil, 7, "hi"]))

    assert encoded == "*3\r\n$-1\r\n:7\r\n$2\r\nhi\r\n"
  end

  test "array/1 encodes an empty list" do
    assert IO.iodata_to_binary(Encoder.array([])) == "*0\r\n"
  end
end
