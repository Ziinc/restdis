defmodule RestdisElectric.SqlParserTest do
  use ExUnit.Case, async: true

  alias RestdisElectric.SqlParser

  defp chain(depth), do: "1" <> String.duplicate("+1", depth)

  test "an expression nested within the depth limit parses" do
    assert {:ok, {:binop, "+", _left, _right}} = SqlParser.parse(chain(100))
  end

  test "an expression nested deeper than the depth limit is an error" do
    assert {:error, message} = SqlParser.parse(chain(200))
    assert message =~ "nested deeper than"
  end

  test "the deepest expression that fits the input size limit is an error, not a crash" do
    assert {:error, message} = SqlParser.parse(chain(4000))
    assert message =~ "nested deeper than"
  end

  test "a 10,000-deep expression is an error, not a crash" do
    assert {:error, _message} = SqlParser.parse(chain(10_000))
  end
end
