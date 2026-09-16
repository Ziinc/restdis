defmodule RestdisServer.Commands.SetnxTest do
  use ExUnit.Case, async: false

  import RestdisServer.TestUtils

  alias RestdisServer.Commands.Get
  alias RestdisServer.Commands.Set
  alias RestdisServer.Commands.Setnx

  setup do
    tenant_id = "tenant_setnx_#{System.unique_integer([:positive])}"
    on_exit(fn -> Restdis.Cache.flush_tenant(tenant_id) end)
    {:ok, tenant_id: tenant_id}
  end

  test "SETNX sets the key when it doesn't exist", %{tenant_id: tenant_id} do
    {reply, _state} = Setnx.run(state(tenant_id), ["mykey", "hello"])
    assert IO.iodata_to_binary(reply) == ":1\r\n"

    {get_reply, _state} = Get.run(state(tenant_id), ["mykey"])
    assert IO.iodata_to_binary(get_reply) == "$5\r\nhello\r\n"
  end

  test "SETNX does not overwrite an existing key", %{tenant_id: tenant_id} do
    Set.run(state(tenant_id), ["mykey", "first"])

    {reply, _state} = Setnx.run(state(tenant_id), ["mykey", "second"])
    assert IO.iodata_to_binary(reply) == ":0\r\n"

    {get_reply, _state} = Get.run(state(tenant_id), ["mykey"])
    assert IO.iodata_to_binary(get_reply) == "$5\r\nfirst\r\n"
  end

  test "SETNX rejects pgrst:* keys", %{tenant_id: tenant_id} do
    {reply, _state} = Setnx.run(state(tenant_id), ["pgrst:t:users:123", "hello"])
    assert IO.iodata_to_binary(reply) =~ "ERR"
  end
end
