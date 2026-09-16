defmodule RestdisServer.Commands.CounterTest do
  use ExUnit.Case, async: false

  import RestdisServer.TestUtils

  alias RestdisServer.Commands.Decr
  alias RestdisServer.Commands.Decrby
  alias RestdisServer.Commands.Incr
  alias RestdisServer.Commands.Incrby
  alias RestdisServer.Commands.Set
  alias RestdisServer.Commands.Ttl

  setup do
    tenant_id = "tenant_counter_#{System.unique_integer([:positive])}"
    on_exit(fn -> Restdis.Cache.flush_tenant(tenant_id) end)
    {:ok, tenant_id: tenant_id}
  end

  test "INCR on a missing key starts at zero", %{tenant_id: tenant_id} do
    {reply, _state} = Incr.run(state(tenant_id), ["counter"])
    assert IO.iodata_to_binary(reply) == ":1\r\n"
  end

  test "INCR increments an existing integer value", %{tenant_id: tenant_id} do
    Set.run(state(tenant_id), ["counter", "10"])

    {reply, _state} = Incr.run(state(tenant_id), ["counter"])
    assert IO.iodata_to_binary(reply) == ":11\r\n"
  end

  test "DECR decrements an existing integer value", %{tenant_id: tenant_id} do
    Set.run(state(tenant_id), ["counter", "10"])

    {reply, _state} = Decr.run(state(tenant_id), ["counter"])
    assert IO.iodata_to_binary(reply) == ":9\r\n"
  end

  test "INCRBY adds the given amount", %{tenant_id: tenant_id} do
    Set.run(state(tenant_id), ["counter", "10"])

    {reply, _state} = Incrby.run(state(tenant_id), ["counter", "5"])
    assert IO.iodata_to_binary(reply) == ":15\r\n"
  end

  test "DECRBY subtracts the given amount", %{tenant_id: tenant_id} do
    Set.run(state(tenant_id), ["counter", "10"])

    {reply, _state} = Decrby.run(state(tenant_id), ["counter", "4"])
    assert IO.iodata_to_binary(reply) == ":6\r\n"
  end

  test "INCR on a non-integer value errors", %{tenant_id: tenant_id} do
    Set.run(state(tenant_id), ["counter", "not-a-number"])

    {reply, _state} = Incr.run(state(tenant_id), ["counter"])
    assert IO.iodata_to_binary(reply) =~ "ERR"
  end

  test "INCRBY with a malformed amount errors", %{tenant_id: tenant_id} do
    {reply, _state} = Incrby.run(state(tenant_id), ["counter", "nope"])
    assert IO.iodata_to_binary(reply) =~ "ERR"
  end

  test "INCR preserves an existing TTL", %{tenant_id: tenant_id} do
    Set.run(state(tenant_id), ["counter", "1", "EX", "60"])
    Incr.run(state(tenant_id), ["counter"])

    {ttl_reply, _state} = Ttl.run(state(tenant_id), ["counter"])

    assert IO.iodata_to_binary(ttl_reply) == ":60\r\n" or
             IO.iodata_to_binary(ttl_reply) == ":59\r\n"
  end

  test "INCR rejects pgrst:* keys", %{tenant_id: tenant_id} do
    {reply, _state} = Incr.run(state(tenant_id), ["pgrst:t:users:123"])
    assert IO.iodata_to_binary(reply) =~ "ERR"
  end

  test "INCR with wrong number of arguments errors", %{tenant_id: tenant_id} do
    {reply, _state} = Incr.run(state(tenant_id), [])
    assert IO.iodata_to_binary(reply) =~ "ERR"
  end
end
