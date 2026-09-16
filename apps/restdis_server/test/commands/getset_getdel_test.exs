defmodule RestdisServer.Commands.GetsetGetdelTest do
  use ExUnit.Case, async: false

  import RestdisServer.TestUtils

  alias RestdisServer.Commands.Exists
  alias RestdisServer.Commands.Get
  alias RestdisServer.Commands.Getdel
  alias RestdisServer.Commands.Getset
  alias RestdisServer.Commands.Set

  setup do
    tenant_id = "tenant_getset_#{System.unique_integer([:positive])}"
    on_exit(fn -> Restdis.Cache.flush_tenant(tenant_id) end)
    {:ok, tenant_id: tenant_id}
  end

  test "GETSET returns nil and sets the value when the key is missing", %{tenant_id: tenant_id} do
    {reply, _state} = Getset.run(state(tenant_id), ["mykey", "hello"])
    assert IO.iodata_to_binary(reply) == "$-1\r\n"

    {get_reply, _state} = Get.run(state(tenant_id), ["mykey"])
    assert IO.iodata_to_binary(get_reply) == "$5\r\nhello\r\n"
  end

  test "GETSET returns the previous value and overwrites it", %{tenant_id: tenant_id} do
    Set.run(state(tenant_id), ["mykey", "first"])

    {reply, _state} = Getset.run(state(tenant_id), ["mykey", "second"])
    assert IO.iodata_to_binary(reply) == "$5\r\nfirst\r\n"

    {get_reply, _state} = Get.run(state(tenant_id), ["mykey"])
    assert IO.iodata_to_binary(get_reply) == "$6\r\nsecond\r\n"
  end

  test "GETDEL returns the value and deletes the key", %{tenant_id: tenant_id} do
    Set.run(state(tenant_id), ["mykey", "hello"])

    {reply, _state} = Getdel.run(state(tenant_id), ["mykey"])
    assert IO.iodata_to_binary(reply) == "$5\r\nhello\r\n"

    {exists_reply, _state} = Exists.run(state(tenant_id), ["mykey"])
    assert IO.iodata_to_binary(exists_reply) == ":0\r\n"
  end

  test "GETDEL on a missing key replies nil", %{tenant_id: tenant_id} do
    {reply, _state} = Getdel.run(state(tenant_id), ["mykey"])
    assert IO.iodata_to_binary(reply) == "$-1\r\n"
  end
end
