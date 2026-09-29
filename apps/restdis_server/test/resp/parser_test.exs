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
            {:more, _missing} -> Parser.parse(part1 <> part2)
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

    test "a bulk not followed by CRLF is a protocol error" do
      assert {:error, :expected_crlf} = Parser.parse("*1\r\n$1\r\nabcd")
    end

    test "a non-numeric bulk length is a protocol error" do
      data = "*1\r\n$notanumber\r\n"
      assert {:error, {:bad_integer, "notanumber"}} = Parser.parse(data)
    end
  end

  describe "negative counts" do
    test "a null array is ignored as an empty command" do
      assert {:ok, [], "rest"} = Parser.parse("*-1\r\nrest")
    end

    test "an array count below -1 is a protocol error" do
      assert {:error, :invalid_multibulk_length} = Parser.parse("*-2\r\n")
    end

    test "a bulk length below -1 is a protocol error" do
      assert {:error, :invalid_bulk_length} = Parser.parse("*1\r\n$-5\r\n")
    end
  end

  describe "missing byte count" do
    test "a partial bulk reports how many bytes it still needs" do
      assert {:more, 4} = Parser.parse("*1\r\n$4\r\nPI")
    end

    test "an incomplete header line needs at least one more byte" do
      assert {:more, 1} = Parser.parse("*1\r\n$4")
    end
  end

  describe "unauthenticated limits" do
    test "an array of 10 elements is accepted" do
      assert {:more, _} = Parser.parse("*10\r\n", false)
    end

    test "an array of more than 10 elements is rejected" do
      assert {:error, :unauthenticated_multibulk_length} = Parser.parse("*11\r\n", false)
    end

    test "a bulk of 16384 bytes is accepted" do
      assert {:more, 16_386} = Parser.parse("*1\r\n$16384\r\n", false)
    end

    test "a bulk longer than 16384 bytes is rejected" do
      assert {:error, :unauthenticated_bulk_length} = Parser.parse("*1\r\n$16385\r\n", false)
    end
  end

  describe "authenticated limits" do
    test "an array of 1048576 elements is accepted" do
      assert {:more, _} = Parser.parse("*1048576\r\n", true)
    end

    test "an array of more than 1048576 elements is rejected" do
      assert {:error, :invalid_multibulk_length} = Parser.parse("*1048577\r\n", true)
    end

    test "a bulk of 512MB is accepted" do
      assert {:more, 536_870_914} = Parser.parse("*1\r\n$536870912\r\n", true)
    end

    test "a bulk longer than 512MB is rejected" do
      assert {:error, :invalid_bulk_length} = Parser.parse("*1\r\n$536870913\r\n", true)
    end
  end

  describe "line length limits" do
    test "an inline line of 64KB without CRLF waits for more data" do
      assert {:more, 1} = Parser.parse(:binary.copy("a", 64 * 1024))
    end

    test "an inline line beyond 64KB without CRLF is rejected" do
      assert {:error, :too_big_inline_request} = Parser.parse(:binary.copy("a", 64 * 1024 + 1))
    end

    test "an array header beyond 64KB without CRLF is rejected" do
      assert {:error, :too_big_count_string} =
               Parser.parse("*" <> :binary.copy("1", 64 * 1024 + 1))
    end
  end
end
