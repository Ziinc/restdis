defmodule RestdisServer.Commands.GetArgumentErrorsTest do
  use ExUnit.Case, async: false

  import RestdisServer.TestUtils

  alias RestdisServer.Commands.Get

  test "GET with the wrong number of arguments replies with an error" do
    {reply, _state} = Get.run(state("tenant_get_args"), [])
    assert IO.iodata_to_binary(reply) =~ "wrong number of arguments"

    {reply, _state} = Get.run(state("tenant_get_args"), ["a", "b"])
    assert IO.iodata_to_binary(reply) =~ "wrong number of arguments"
  end
end
