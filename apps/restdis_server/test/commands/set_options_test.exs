defmodule RestdisServer.Commands.SetOptionsTest do
  use ExUnit.Case, async: false

  alias RestdisServer.Commands.Get
  alias RestdisServer.Commands.Set
  alias RestdisServer.Commands.Ttl

  setup do
    tenant_id = "tenant_set_opts_#{System.unique_integer([:positive])}"
    on_exit(fn -> Restdis.Cache.flush_tenant(tenant_id) end)
    {:ok, tenant_id: tenant_id}
  end

  defp state(tenant_id), do: %{authenticated?: true, tenant_id: tenant_id, buffer: <<>>}

  test "SET NX only writes when the key is missing", %{tenant_id: tenant_id} do
    {reply, _state} = Set.run(state(tenant_id), ["mykey", "first", "NX"])
    assert IO.iodata_to_binary(reply) == "+OK\r\n"

    {reply2, _state} = Set.run(state(tenant_id), ["mykey", "second", "NX"])
    assert IO.iodata_to_binary(reply2) == "$-1\r\n"

    {get_reply, _state} = Get.run(state(tenant_id), ["mykey"])
    assert IO.iodata_to_binary(get_reply) == "$5\r\nfirst\r\n"
  end

  test "SET XX only writes when the key already exists", %{tenant_id: tenant_id} do
    {reply, _state} = Set.run(state(tenant_id), ["mykey", "first", "XX"])
    assert IO.iodata_to_binary(reply) == "$-1\r\n"

    Set.run(state(tenant_id), ["mykey", "first"])

    {reply2, _state} = Set.run(state(tenant_id), ["mykey", "second", "XX"])
    assert IO.iodata_to_binary(reply2) == "+OK\r\n"

    {get_reply, _state} = Get.run(state(tenant_id), ["mykey"])
    assert IO.iodata_to_binary(get_reply) == "$6\r\nsecond\r\n"
  end

  test "SET NX and XX together is a syntax error", %{tenant_id: tenant_id} do
    {reply, _state} = Set.run(state(tenant_id), ["mykey", "value", "NX", "XX"])
    assert IO.iodata_to_binary(reply) =~ "ERR"
  end

  test "SET PX sets a millisecond TTL", %{tenant_id: tenant_id} do
    {reply, _state} = Set.run(state(tenant_id), ["mykey", "hello", "PX", "60000"])
    assert IO.iodata_to_binary(reply) == "+OK\r\n"

    {ttl_reply, _state} = Ttl.run(state(tenant_id), ["mykey"])

    assert IO.iodata_to_binary(ttl_reply) == ":60\r\n" or
             IO.iodata_to_binary(ttl_reply) == ":59\r\n"
  end

  test "SET KEEPTTL preserves an existing TTL when overwriting", %{tenant_id: tenant_id} do
    Set.run(state(tenant_id), ["mykey", "first", "EX", "60"])

    {reply, _state} = Set.run(state(tenant_id), ["mykey", "second", "KEEPTTL"])
    assert IO.iodata_to_binary(reply) == "+OK\r\n"

    {ttl_reply, _state} = Ttl.run(state(tenant_id), ["mykey"])

    assert IO.iodata_to_binary(ttl_reply) == ":60\r\n" or
             IO.iodata_to_binary(ttl_reply) == ":59\r\n"
  end

  test "SET without KEEPTTL clears an existing TTL", %{tenant_id: tenant_id} do
    Set.run(state(tenant_id), ["mykey", "first", "EX", "60"])
    Set.run(state(tenant_id), ["mykey", "second"])

    {ttl_reply, _state} = Ttl.run(state(tenant_id), ["mykey"])
    assert IO.iodata_to_binary(ttl_reply) == ":-1\r\n"
  end

  test "SET with a malformed PX value errors", %{tenant_id: tenant_id} do
    {reply, _state} = Set.run(state(tenant_id), ["mykey", "hello", "PX", "notanumber"])
    assert IO.iodata_to_binary(reply) =~ "ERR"
  end
end
