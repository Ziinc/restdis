defmodule RestdisServer.Commands.WrongArityAndReservedKeysTest do
  use ExUnit.Case, async: false

  alias RestdisServer.Commands.Append
  alias RestdisServer.Commands.Copy
  alias RestdisServer.Commands.Decr
  alias RestdisServer.Commands.Decrby
  alias RestdisServer.Commands.Expire
  alias RestdisServer.Commands.Getdel
  alias RestdisServer.Commands.Getset
  alias RestdisServer.Commands.Incrby
  alias RestdisServer.Commands.Persist
  alias RestdisServer.Commands.Pexpire
  alias RestdisServer.Commands.Rename
  alias RestdisServer.Commands.Renamenx
  alias RestdisServer.Commands.Set
  alias RestdisServer.Commands.Setnx
  alias RestdisServer.Commands.Strlen

  setup do
    tenant_id = "tenant_arity_#{System.unique_integer([:positive])}"
    on_exit(fn -> Restdis.Cache.flush_tenant(tenant_id) end)
    {:ok, tenant_id: tenant_id}
  end

  defp state(tenant_id), do: %{authenticated?: true, tenant_id: tenant_id, buffer: <<>>}

  test "DECR with the wrong number of arguments errors", %{tenant_id: tenant_id} do
    {reply, _state} = Decr.run(state(tenant_id), [])
    assert IO.iodata_to_binary(reply) =~ "wrong number of arguments"
  end

  test "DECRBY with the wrong number of arguments errors", %{tenant_id: tenant_id} do
    {reply, _state} = Decrby.run(state(tenant_id), ["onlykey"])
    assert IO.iodata_to_binary(reply) =~ "wrong number of arguments"
  end

  test "DECRBY with a malformed amount errors", %{tenant_id: tenant_id} do
    {reply, _state} = Decrby.run(state(tenant_id), ["mykey", "nope"])
    assert IO.iodata_to_binary(reply) =~ "ERR"
  end

  test "INCRBY with the wrong number of arguments errors", %{tenant_id: tenant_id} do
    {reply, _state} = Incrby.run(state(tenant_id), ["onlykey"])
    assert IO.iodata_to_binary(reply) =~ "wrong number of arguments"
  end

  test "EXPIRE with the wrong number of arguments errors", %{tenant_id: tenant_id} do
    {reply, _state} = Expire.run(state(tenant_id), ["onlykey"])
    assert IO.iodata_to_binary(reply) =~ "wrong number of arguments"
  end

  test "PEXPIRE with the wrong number of arguments errors", %{tenant_id: tenant_id} do
    {reply, _state} = Pexpire.run(state(tenant_id), ["onlykey"])
    assert IO.iodata_to_binary(reply) =~ "wrong number of arguments"
  end

  test "PEXPIRE with a malformed millis value errors", %{tenant_id: tenant_id} do
    {reply, _state} = Pexpire.run(state(tenant_id), ["mykey", "nope"])
    assert IO.iodata_to_binary(reply) =~ "ERR"
  end

  test "PERSIST with the wrong number of arguments errors", %{tenant_id: tenant_id} do
    {reply, _state} = Persist.run(state(tenant_id), [])
    assert IO.iodata_to_binary(reply) =~ "wrong number of arguments"
  end

  test "PERSIST rejects pgrst:* keys", %{tenant_id: tenant_id} do
    {reply, _state} = Persist.run(state(tenant_id), ["pgrst:t:users:123"])
    assert IO.iodata_to_binary(reply) =~ "ERR"
  end

  test "GETSET with the wrong number of arguments errors", %{tenant_id: tenant_id} do
    {reply, _state} = Getset.run(state(tenant_id), ["onlykey"])
    assert IO.iodata_to_binary(reply) =~ "wrong number of arguments"
  end

  test "GETSET rejects pgrst:* keys", %{tenant_id: tenant_id} do
    {reply, _state} = Getset.run(state(tenant_id), ["pgrst:t:users:123", "value"])
    assert IO.iodata_to_binary(reply) =~ "ERR"
  end

  test "GETDEL with the wrong number of arguments errors", %{tenant_id: tenant_id} do
    {reply, _state} = Getdel.run(state(tenant_id), [])
    assert IO.iodata_to_binary(reply) =~ "wrong number of arguments"
  end

  test "GETDEL rejects pgrst:* keys", %{tenant_id: tenant_id} do
    {reply, _state} = Getdel.run(state(tenant_id), ["pgrst:t:users:123"])
    assert IO.iodata_to_binary(reply) =~ "ERR"
  end

  test "APPEND with the wrong number of arguments errors", %{tenant_id: tenant_id} do
    {reply, _state} = Append.run(state(tenant_id), ["onlykey"])
    assert IO.iodata_to_binary(reply) =~ "wrong number of arguments"
  end

  test "APPEND rejects pgrst:* keys", %{tenant_id: tenant_id} do
    {reply, _state} = Append.run(state(tenant_id), ["pgrst:t:users:123", "value"])
    assert IO.iodata_to_binary(reply) =~ "ERR"
  end

  test "STRLEN with the wrong number of arguments errors", %{tenant_id: tenant_id} do
    {reply, _state} = Strlen.run(state(tenant_id), [])
    assert IO.iodata_to_binary(reply) =~ "wrong number of arguments"
  end

  test "STRLEN rejects pgrst:* keys", %{tenant_id: tenant_id} do
    {reply, _state} = Strlen.run(state(tenant_id), ["pgrst:t:users:123"])
    assert IO.iodata_to_binary(reply) =~ "ERR"
  end

  test "RENAME with the wrong number of arguments errors", %{tenant_id: tenant_id} do
    {reply, _state} = Rename.run(state(tenant_id), ["onlykey"])
    assert IO.iodata_to_binary(reply) =~ "wrong number of arguments"
  end

  test "RENAMENX with the wrong number of arguments errors", %{tenant_id: tenant_id} do
    {reply, _state} = Renamenx.run(state(tenant_id), ["onlykey"])
    assert IO.iodata_to_binary(reply) =~ "wrong number of arguments"
  end

  test "RENAMENX on a missing source errors", %{tenant_id: tenant_id} do
    {reply, _state} = Renamenx.run(state(tenant_id), ["src", "dst"])
    assert IO.iodata_to_binary(reply) =~ "ERR no such key"
  end

  test "SETNX with the wrong number of arguments errors", %{tenant_id: tenant_id} do
    {reply, _state} = Setnx.run(state(tenant_id), ["onlykey"])
    assert IO.iodata_to_binary(reply) =~ "wrong number of arguments"
  end

  test "COPY with the wrong number of arguments errors", %{tenant_id: tenant_id} do
    {reply, _state} = Copy.run(state(tenant_id), ["onlykey"])
    assert IO.iodata_to_binary(reply) =~ "wrong number of arguments"
  end

  test "COPY rejects pgrst:* source keys", %{tenant_id: tenant_id} do
    {reply, _state} = Copy.run(state(tenant_id), ["pgrst:t:users:123", "dst"])
    assert IO.iodata_to_binary(reply) =~ "ERR"
  end

  test "COPY rejects pgrst:* destination keys", %{tenant_id: tenant_id} do
    Set.run(state(tenant_id), ["src", "hello"])
    {reply, _state} = Copy.run(state(tenant_id), ["src", "pgrst:t:users:123"])
    assert IO.iodata_to_binary(reply) =~ "ERR"
  end

  test "RENAME rejects pgrst:* source keys", %{tenant_id: tenant_id} do
    {reply, _state} = Rename.run(state(tenant_id), ["pgrst:t:users:123", "dst"])
    assert IO.iodata_to_binary(reply) =~ "ERR"
  end

  test "RENAME rejects pgrst:* destination keys", %{tenant_id: tenant_id} do
    Set.run(state(tenant_id), ["src", "hello"])
    {reply, _state} = Rename.run(state(tenant_id), ["src", "pgrst:t:users:123"])
    assert IO.iodata_to_binary(reply) =~ "ERR"
  end

  test "RENAMENX rejects pgrst:* source keys", %{tenant_id: tenant_id} do
    {reply, _state} = Renamenx.run(state(tenant_id), ["pgrst:t:users:123", "dst"])
    assert IO.iodata_to_binary(reply) =~ "ERR"
  end

  test "DECRBY on a non-integer stored value errors", %{tenant_id: tenant_id} do
    Set.run(state(tenant_id), ["counter", "not-a-number"])
    {reply, _state} = Decrby.run(state(tenant_id), ["counter", "5"])
    assert IO.iodata_to_binary(reply) =~ "ERR"
  end

  test "INCRBY on a non-integer stored value errors", %{tenant_id: tenant_id} do
    Set.run(state(tenant_id), ["counter", "not-a-number"])
    {reply, _state} = Incrby.run(state(tenant_id), ["counter", "5"])
    assert IO.iodata_to_binary(reply) =~ "ERR"
  end

  test "SETNX with the wrong number of arguments errors (zero args)", %{tenant_id: tenant_id} do
    {reply, _state} = Setnx.run(state(tenant_id), [])
    assert IO.iodata_to_binary(reply) =~ "wrong number of arguments"
  end

  test "APPEND rejects <table>:<primary_key>-style keys", %{tenant_id: tenant_id} do
    {reply, _state} = Append.run(state(tenant_id), ["users:123", "value"])
    assert IO.iodata_to_binary(reply) =~ "reserved"
  end

  test "STRLEN rejects <table>:<primary_key>-style keys", %{tenant_id: tenant_id} do
    {reply, _state} = Strlen.run(state(tenant_id), ["users:123"])
    assert IO.iodata_to_binary(reply) =~ "reserved"
  end

  test "GETSET rejects <table>:<primary_key>-style keys", %{tenant_id: tenant_id} do
    {reply, _state} = Getset.run(state(tenant_id), ["users:123", "value"])
    assert IO.iodata_to_binary(reply) =~ "reserved"
  end

  test "GETDEL rejects <table>:<primary_key>-style keys", %{tenant_id: tenant_id} do
    {reply, _state} = Getdel.run(state(tenant_id), ["users:123"])
    assert IO.iodata_to_binary(reply) =~ "reserved"
  end

  test "SETNX rejects <table>:<primary_key>-style keys", %{tenant_id: tenant_id} do
    {reply, _state} = Setnx.run(state(tenant_id), ["users:123", "value"])
    assert IO.iodata_to_binary(reply) =~ "reserved"
  end

  test "COPY rejects <table>:<primary_key>-style source keys", %{tenant_id: tenant_id} do
    {reply, _state} = Copy.run(state(tenant_id), ["users:123", "dst"])
    assert IO.iodata_to_binary(reply) =~ "reserved"
  end

  test "PERSIST rejects <table>:<primary_key>-style keys", %{tenant_id: tenant_id} do
    {reply, _state} = Persist.run(state(tenant_id), ["users:123"])
    assert IO.iodata_to_binary(reply) =~ "reserved"
  end
end
