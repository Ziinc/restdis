defmodule RestdisServer.Commands.AppendStrlenTest do
  use ExUnit.Case, async: false

  import RestdisServer.TestUtils

  alias RestdisServer.Commands.Append
  alias RestdisServer.Commands.Get
  alias RestdisServer.Commands.Set
  alias RestdisServer.Commands.Strlen
  alias RestdisServer.Commands.Ttl

  setup do
    tenant_id = "tenant_append_#{System.unique_integer([:positive])}"
    on_exit(fn -> Restdis.Cache.flush_tenant(tenant_id) end)
    {:ok, tenant_id: tenant_id}
  end

  test "APPEND creates the key when missing", %{tenant_id: tenant_id} do
    {reply, _state} = Append.run(state(tenant_id), ["mykey", "hello"])
    assert IO.iodata_to_binary(reply) == ":5\r\n"

    {get_reply, _state} = Get.run(state(tenant_id), ["mykey"])
    assert IO.iodata_to_binary(get_reply) == "$5\r\nhello\r\n"
  end

  test "APPEND concatenates onto an existing value", %{tenant_id: tenant_id} do
    Set.run(state(tenant_id), ["mykey", "hello"])

    {reply, _state} = Append.run(state(tenant_id), ["mykey", " world"])
    assert IO.iodata_to_binary(reply) == ":11\r\n"

    {get_reply, _state} = Get.run(state(tenant_id), ["mykey"])
    assert IO.iodata_to_binary(get_reply) == "$11\r\nhello world\r\n"
  end

  test "APPEND preserves an existing TTL", %{tenant_id: tenant_id} do
    Set.run(state(tenant_id), ["mykey", "hello", "EX", "60"])
    Append.run(state(tenant_id), ["mykey", " world"])

    {ttl_reply, _state} = Ttl.run(state(tenant_id), ["mykey"])

    assert IO.iodata_to_binary(ttl_reply) == ":60\r\n" or
             IO.iodata_to_binary(ttl_reply) == ":59\r\n"
  end

  test "STRLEN returns the byte length of an existing value", %{tenant_id: tenant_id} do
    Set.run(state(tenant_id), ["mykey", "hello"])

    {reply, _state} = Strlen.run(state(tenant_id), ["mykey"])
    assert IO.iodata_to_binary(reply) == ":5\r\n"
  end

  test "STRLEN on a missing key replies 0", %{tenant_id: tenant_id} do
    {reply, _state} = Strlen.run(state(tenant_id), ["mykey"])
    assert IO.iodata_to_binary(reply) == ":0\r\n"
  end
end
