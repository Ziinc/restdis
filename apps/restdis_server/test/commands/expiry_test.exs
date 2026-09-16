defmodule RestdisServer.Commands.ExpiryTest do
  use ExUnit.Case, async: false

  alias RestdisServer.Commands.Exists
  alias RestdisServer.Commands.Expire
  alias RestdisServer.Commands.Get
  alias RestdisServer.Commands.Pexpire
  alias RestdisServer.Commands.Set
  alias RestdisServer.Commands.Ttl

  setup do
    tenant_id = "tenant_expiry_#{System.unique_integer([:positive])}"
    on_exit(fn -> Restdis.Cache.flush_tenant(tenant_id) end)
    {:ok, tenant_id: tenant_id}
  end

  defp state(tenant_id), do: %{authenticated?: true, tenant_id: tenant_id, buffer: <<>>}

  test "EXPIRE sets a TTL on an existing key", %{tenant_id: tenant_id} do
    Set.run(state(tenant_id), ["mykey", "hello"])

    {reply, _state} = Expire.run(state(tenant_id), ["mykey", "60"])
    assert IO.iodata_to_binary(reply) == ":1\r\n"

    {ttl_reply, _state} = Ttl.run(state(tenant_id), ["mykey"])

    assert IO.iodata_to_binary(ttl_reply) == ":60\r\n" or
             IO.iodata_to_binary(ttl_reply) == ":59\r\n"
  end

  test "EXPIRE on a missing key replies 0", %{tenant_id: tenant_id} do
    {reply, _state} = Expire.run(state(tenant_id), ["mykey", "60"])
    assert IO.iodata_to_binary(reply) == ":0\r\n"
  end

  test "EXPIRE with a non-positive TTL deletes the key", %{tenant_id: tenant_id} do
    Set.run(state(tenant_id), ["mykey", "hello"])

    {reply, _state} = Expire.run(state(tenant_id), ["mykey", "0"])
    assert IO.iodata_to_binary(reply) == ":1\r\n"

    {exists_reply, _state} = Exists.run(state(tenant_id), ["mykey"])
    assert IO.iodata_to_binary(exists_reply) == ":0\r\n"
  end

  test "EXPIRE with a malformed seconds value errors", %{tenant_id: tenant_id} do
    {reply, _state} = Expire.run(state(tenant_id), ["mykey", "nope"])
    assert IO.iodata_to_binary(reply) =~ "ERR"
  end

  test "PEXPIRE sets a millisecond TTL on an existing key", %{tenant_id: tenant_id} do
    Set.run(state(tenant_id), ["mykey", "hello"])

    {reply, _state} = Pexpire.run(state(tenant_id), ["mykey", "60000"])
    assert IO.iodata_to_binary(reply) == ":1\r\n"

    {get_reply, _state} = Get.run(state(tenant_id), ["mykey"])
    assert IO.iodata_to_binary(get_reply) == "$5\r\nhello\r\n"
  end

  test "PEXPIRE on a missing key replies 0", %{tenant_id: tenant_id} do
    {reply, _state} = Pexpire.run(state(tenant_id), ["mykey", "1000"])
    assert IO.iodata_to_binary(reply) == ":0\r\n"
  end

  test "EXPIRE with a non-positive TTL on a missing key replies 0", %{tenant_id: tenant_id} do
    {reply, _state} = Expire.run(state(tenant_id), ["mykey", "0"])
    assert IO.iodata_to_binary(reply) == ":0\r\n"
  end

  test "PEXPIRE with a non-positive TTL deletes the key", %{tenant_id: tenant_id} do
    Set.run(state(tenant_id), ["mykey", "hello"])

    {reply, _state} = Pexpire.run(state(tenant_id), ["mykey", "0"])
    assert IO.iodata_to_binary(reply) == ":1\r\n"

    {exists_reply, _state} = Exists.run(state(tenant_id), ["mykey"])
    assert IO.iodata_to_binary(exists_reply) == ":0\r\n"
  end

  test "EXPIRE rejects pgrst:* keys", %{tenant_id: tenant_id} do
    {reply, _state} = Expire.run(state(tenant_id), ["pgrst:t:users:123", "60"])
    assert IO.iodata_to_binary(reply) =~ "ERR"
  end
end
