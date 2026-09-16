defmodule RestdisServer.Commands.RenameCopyTest do
  use ExUnit.Case, async: false

  import RestdisServer.TestUtils

  alias RestdisServer.Commands.Copy
  alias RestdisServer.Commands.Exists
  alias RestdisServer.Commands.Get
  alias RestdisServer.Commands.Rename
  alias RestdisServer.Commands.Renamenx
  alias RestdisServer.Commands.Set
  alias RestdisServer.Commands.Ttl

  setup do
    tenant_id = "tenant_rename_#{System.unique_integer([:positive])}"
    on_exit(fn -> Restdis.Cache.flush_tenant(tenant_id) end)
    {:ok, tenant_id: tenant_id}
  end

  test "RENAME moves a value, overwriting the destination", %{tenant_id: tenant_id} do
    Set.run(state(tenant_id), ["src", "hello"])
    Set.run(state(tenant_id), ["dst", "old"])

    {reply, _state} = Rename.run(state(tenant_id), ["src", "dst"])
    assert IO.iodata_to_binary(reply) == "+OK\r\n"

    {get_dst, _state} = Get.run(state(tenant_id), ["dst"])
    assert IO.iodata_to_binary(get_dst) == "$5\r\nhello\r\n"

    {exists_src, _state} = Exists.run(state(tenant_id), ["src"])
    assert IO.iodata_to_binary(exists_src) == ":0\r\n"
  end

  test "RENAME preserves the source's TTL", %{tenant_id: tenant_id} do
    Set.run(state(tenant_id), ["src", "hello", "EX", "60"])
    Rename.run(state(tenant_id), ["src", "dst"])

    {ttl_reply, _state} = Ttl.run(state(tenant_id), ["dst"])

    assert IO.iodata_to_binary(ttl_reply) == ":60\r\n" or
             IO.iodata_to_binary(ttl_reply) == ":59\r\n"
  end

  test "RENAME on a missing source errors", %{tenant_id: tenant_id} do
    {reply, _state} = Rename.run(state(tenant_id), ["src", "dst"])
    assert IO.iodata_to_binary(reply) =~ "ERR no such key"
  end

  test "RENAMENX does not overwrite an existing destination", %{tenant_id: tenant_id} do
    Set.run(state(tenant_id), ["src", "hello"])
    Set.run(state(tenant_id), ["dst", "old"])

    {reply, _state} = Renamenx.run(state(tenant_id), ["src", "dst"])
    assert IO.iodata_to_binary(reply) == ":0\r\n"

    {get_dst, _state} = Get.run(state(tenant_id), ["dst"])
    assert IO.iodata_to_binary(get_dst) == "$3\r\nold\r\n"
  end

  test "RENAMENX renames when the destination is free", %{tenant_id: tenant_id} do
    Set.run(state(tenant_id), ["src", "hello"])

    {reply, _state} = Renamenx.run(state(tenant_id), ["src", "dst"])
    assert IO.iodata_to_binary(reply) == ":1\r\n"

    {get_dst, _state} = Get.run(state(tenant_id), ["dst"])
    assert IO.iodata_to_binary(get_dst) == "$5\r\nhello\r\n"
  end

  test "COPY duplicates a value without removing the source", %{tenant_id: tenant_id} do
    Set.run(state(tenant_id), ["src", "hello"])

    {reply, _state} = Copy.run(state(tenant_id), ["src", "dst"])
    assert IO.iodata_to_binary(reply) == ":1\r\n"

    {get_src, _state} = Get.run(state(tenant_id), ["src"])
    assert IO.iodata_to_binary(get_src) == "$5\r\nhello\r\n"

    {get_dst, _state} = Get.run(state(tenant_id), ["dst"])
    assert IO.iodata_to_binary(get_dst) == "$5\r\nhello\r\n"
  end

  test "COPY without REPLACE does not overwrite an existing destination", %{
    tenant_id: tenant_id
  } do
    Set.run(state(tenant_id), ["src", "hello"])
    Set.run(state(tenant_id), ["dst", "old"])

    {reply, _state} = Copy.run(state(tenant_id), ["src", "dst"])
    assert IO.iodata_to_binary(reply) == ":0\r\n"
  end

  test "COPY REPLACE overwrites an existing destination", %{tenant_id: tenant_id} do
    Set.run(state(tenant_id), ["src", "hello"])
    Set.run(state(tenant_id), ["dst", "old"])

    {reply, _state} = Copy.run(state(tenant_id), ["src", "dst", "REPLACE"])
    assert IO.iodata_to_binary(reply) == ":1\r\n"

    {get_dst, _state} = Get.run(state(tenant_id), ["dst"])
    assert IO.iodata_to_binary(get_dst) == "$5\r\nhello\r\n"
  end

  test "COPY on a missing source replies 0", %{tenant_id: tenant_id} do
    {reply, _state} = Copy.run(state(tenant_id), ["src", "dst"])
    assert IO.iodata_to_binary(reply) == ":0\r\n"
  end
end
