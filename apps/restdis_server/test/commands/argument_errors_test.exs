defmodule RestdisServer.Commands.ArgumentErrorsTest do
  use ExUnit.Case, async: false

  import RestdisServer.TestUtils

  alias RestdisServer.Commands.Auth
  alias RestdisServer.Commands.Del
  alias RestdisServer.Commands.Exists
  alias RestdisServer.Commands.Mget
  alias RestdisServer.Commands.Set
  alias RestdisServer.Commands.Ttl

  setup do
    tenant_id = "tenant_arg_errors_#{System.unique_integer([:positive])}"
    on_exit(fn -> Restdis.Cache.flush_tenant(tenant_id) end)
    {:ok, tenant_id: tenant_id}
  end

  test "AUTH with the wrong number of arguments replies with an error" do
    {reply, _state} = Auth.run(%{authenticated?: false}, [])
    assert IO.iodata_to_binary(reply) =~ "wrong number of arguments"

    {reply, _state} = Auth.run(%{authenticated?: false}, ["one", "two"])
    assert IO.iodata_to_binary(reply) =~ "wrong number of arguments"
  end

  test "EXISTS with no keys replies with an error", %{tenant_id: tenant_id} do
    {reply, _state} = Exists.run(state(tenant_id), [])
    assert IO.iodata_to_binary(reply) =~ "wrong number of arguments"
  end

  test "MGET with no keys replies with an error", %{tenant_id: tenant_id} do
    {reply, _state} = Mget.run(state(tenant_id), [])
    assert IO.iodata_to_binary(reply) =~ "wrong number of arguments"
  end

  test "DEL with no keys replies with an error", %{tenant_id: tenant_id} do
    {reply, _state} = Del.run(state(tenant_id), [])
    assert IO.iodata_to_binary(reply) =~ "wrong number of arguments"
  end

  test "DEL skips wire keys that fail to decode", %{tenant_id: tenant_id} do
    Set.run(state(tenant_id), ["mykey", "value"])

    {reply, _state} = Del.run(state(tenant_id), ["not-a-known-scheme:::", "mykey"])
    assert IO.iodata_to_binary(reply) == ":1\r\n"
  end

  test "TTL with the wrong number of arguments replies with an error", %{tenant_id: tenant_id} do
    {reply, _state} = Ttl.run(state(tenant_id), [])
    assert IO.iodata_to_binary(reply) =~ "wrong number of arguments"

    {reply, _state} = Ttl.run(state(tenant_id), ["a", "b"])
    assert IO.iodata_to_binary(reply) =~ "wrong number of arguments"
  end

  test "TTL of a key that was never set replies -2", %{tenant_id: tenant_id} do
    {reply, _state} = Ttl.run(state(tenant_id), ["nonexistent"])
    assert IO.iodata_to_binary(reply) == ":-2\r\n"
  end

  test "TTL of an undecodable key replies with an error", %{tenant_id: tenant_id} do
    {reply, _state} = Ttl.run(state(tenant_id), ["not:a:pgrst:key"])
    assert IO.iodata_to_binary(reply) == "-ERR only PGRST.* keys are supported\r\n"
  end

  test "TTL of a key with an expiry replies with seconds remaining", %{tenant_id: tenant_id} do
    Set.run(state(tenant_id), ["mykey", "value", "EX", "60"])

    {reply, _state} = Ttl.run(state(tenant_id), ["mykey"])
    assert IO.iodata_to_binary(reply) == ":60\r\n" or IO.iodata_to_binary(reply) == ":59\r\n"
  end
end
