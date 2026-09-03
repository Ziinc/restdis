defmodule RestdisElectric.MessageTest do
  use ExUnit.Case, async: true

  alias RestdisElectric.Message

  test "change/4 builds a change message" do
    message = Message.change({0, 0}, :insert, "1", %{"id" => 1})
    assert message.operation == :insert
    assert message.key == "1"
    assert message.value == %{"id" => 1}
    refute Message.control?(message)
  end

  test "control/2 builds a control message" do
    message = Message.control({0, :inf}, :up_to_date)
    assert message.control == :up_to_date
    assert Message.control?(message)
  end
end
