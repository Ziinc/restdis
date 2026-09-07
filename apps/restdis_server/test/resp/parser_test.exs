defmodule RestdisServer.RESP.ParserTest do
  use ExUnit.Case, async: true

  alias RestdisServer.RESP.Parser

  describe "array of bulk strings" do
    test "parses a simple command" do
      data = "*1\r\n$4\r\nPING\r\n"
      assert {:ok, ["PING"], ""} = Parser.parse(data)
    end

    test "parses command with args" do
      data = "*2\r\n$3\r\nGET\r\n$5\r\nhello\r\n"
      assert {:ok, ["GET", "hello"], ""} = Parser.parse(data)
    end

    test "parses empty array" do
      data = "*0\r\n"
      assert {:ok, [], ""} = Parser.parse(data)
    end

    test "null bulk string" do
      data = "*2\r\n$4\r\nMGET\r\n$-1\r\n"
      assert {:ok, ["MGET", nil], ""} = Parser.parse(data)
    end

    test "leaves rest unconsumed" do
      data = "*1\r\n$4\r\nPING\r\nextra"
      assert {:ok, ["PING"], "extra"} = Parser.parse(data)
    end

    test "partial frame returns more" do
      data = "*2\r\n$3\r\nGET\r\n$5\r\nhel"
      assert {:more, _} = Parser.parse(data)
    end

    test "incomplete header returns more" do
      assert {:more, _} = Parser.parse("*2")
    end
  end

  describe "inline command fallback" do
    test "parses inline PING" do
      assert {:ok, ["PING"], ""} = Parser.parse("PING\r\n")
    end

    test "parses inline command with args" do
      assert {:ok, ["AUTH", "key123"], ""} = Parser.parse("AUTH key123\r\n")
    end
  end

  describe "property: split at any offset" do
    test "single split reassembles to same result" do
      full = "*2\r\n$3\r\nGET\r\n$5\r\nhello\r\n"
      expected = Parser.parse(full)

      for split <- 1..(byte_size(full) - 1) do
        <<part1::binary-size(split), part2::binary>> = full

        result =
          case Parser.parse(part1) do
            {:ok, cmd, rest} -> {:ok, cmd, rest <> part2}
            {:more, rest} -> Parser.parse(rest <> part2)
            other -> other
          end

        assert result == expected,
               "split at #{split}: expected #{inspect(expected)}, got #{inspect(result)}"
      end
    end
  end

  describe "malformed input" do
    test "a bulk item that isn't $-prefixed is a protocol error" do
      data = "*1\r\n:not-a-dollar\r\n"
      assert {:error, :expected_bulk_string} = Parser.parse(data)
    end

    test "a non-numeric bulk length is a protocol error" do
      data = "*1\r\n$notanumber\r\n"
      assert {:error, {:bad_integer, "notanumber"}} = Parser.parse(data)
    end
  end
end
