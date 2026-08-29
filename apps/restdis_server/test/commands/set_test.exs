defmodule RestdisServer.Commands.SetTest do
  use ExUnit.Case, async: false

  alias RestdisServer.Commands.Del
  alias RestdisServer.Commands.Exists
  alias RestdisServer.Commands.Get
  alias RestdisServer.Commands.Mget
  alias RestdisServer.Commands.Set
  alias RestdisServer.Commands.Ttl

  setup do
    tenant_id = "tenant_set_#{System.unique_integer([:positive])}"
    on_exit(fn -> Restdis.Cache.flush_tenant(tenant_id) end)
    {:ok, tenant_id: tenant_id}
  end

  defp state(tenant_id), do: %{authenticated?: true, tenant_id: tenant_id, buffer: <<>>}

  test "SET key value stores a plain value retrievable via GET", %{tenant_id: tenant_id} do
    {set_reply, _state} = Set.run(state(tenant_id), ["mykey", "hello"])
    assert IO.iodata_to_binary(set_reply) == "+OK\r\n"

    {get_reply, _state} = Get.run(state(tenant_id), ["mykey"])
    assert IO.iodata_to_binary(get_reply) == "$5\r\nhello\r\n"
  end

  test "SET key value EX <seconds> sets a TTL readable via TTL", %{tenant_id: tenant_id} do
    {set_reply, _state} = Set.run(state(tenant_id), ["mykey", "hello", "EX", "60"])
    assert IO.iodata_to_binary(set_reply) == "+OK\r\n"

    {ttl_reply, _state} = Ttl.run(state(tenant_id), ["mykey"])
    assert IO.iodata_to_binary(ttl_reply) == ":60\r\n" or
             IO.iodata_to_binary(ttl_reply) == ":59\r\n"
  end

  test "SET key value without EX has no TTL (-1)", %{tenant_id: tenant_id} do
    Set.run(state(tenant_id), ["mykey", "hello"])

    {ttl_reply, _state} = Ttl.run(state(tenant_id), ["mykey"])
    assert IO.iodata_to_binary(ttl_reply) == ":-1\r\n"
  end

  test "SET overwrites an existing key", %{tenant_id: tenant_id} do
    Set.run(state(tenant_id), ["mykey", "first"])
    Set.run(state(tenant_id), ["mykey", "second"])

    {get_reply, _state} = Get.run(state(tenant_id), ["mykey"])
    assert IO.iodata_to_binary(get_reply) == "$6\r\nsecond\r\n"
  end

  test "SET interacts with EXISTS", %{tenant_id: tenant_id} do
    {exists_before, _state} = Exists.run(state(tenant_id), ["mykey"])
    assert IO.iodata_to_binary(exists_before) == ":0\r\n"

    Set.run(state(tenant_id), ["mykey", "hello"])

    {exists_after, _state} = Exists.run(state(tenant_id), ["mykey"])
    assert IO.iodata_to_binary(exists_after) == ":1\r\n"
  end

  test "SET interacts with DEL", %{tenant_id: tenant_id} do
    Set.run(state(tenant_id), ["mykey", "hello"])

    {del_reply, _state} = Del.run(state(tenant_id), ["mykey"])
    assert IO.iodata_to_binary(del_reply) == ":1\r\n"

    {get_reply, _state} = Get.run(state(tenant_id), ["mykey"])
    assert IO.iodata_to_binary(get_reply) == "$-1\r\n"
  end

  test "SET interacts with MGET", %{tenant_id: tenant_id} do
    Set.run(state(tenant_id), ["key1", "one"])
    Set.run(state(tenant_id), ["key2", "two"])

    {mget_reply, _state} = Mget.run(state(tenant_id), ["key1", "key2", "missing"])
    wire = IO.iodata_to_binary(mget_reply)

    assert wire ==
             "*3\r\n$3\r\none\r\n$3\r\ntwo\r\n$-1\r\n"
  end

  test "SET rejects PGRST-managed cache keys (pgrst:* wire format)", %{tenant_id: tenant_id} do
    {reply, _state} = Set.run(state(tenant_id), ["pgrst:t:users:123", "hello"])
    assert IO.iodata_to_binary(reply) =~ "ERR"
  end

  test "SET rejects keys containing a colon (reserved <table>:<pk> namespace)", %{
    tenant_id: tenant_id
  } do
    {reply, _state} = Set.run(state(tenant_id), ["products:42", "hello"])
    assert IO.iodata_to_binary(reply) =~ "ERR"
  end

  test "SET with wrong number of arguments errors", %{tenant_id: tenant_id} do
    {reply, _state} = Set.run(state(tenant_id), ["onlykey"])
    assert IO.iodata_to_binary(reply) =~ "ERR"
  end

  test "SET with a malformed EX value errors", %{tenant_id: tenant_id} do
    {reply, _state} = Set.run(state(tenant_id), ["mykey", "hello", "EX", "notanumber"])
    assert IO.iodata_to_binary(reply) =~ "ERR"
  end
end
