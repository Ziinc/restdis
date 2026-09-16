defmodule RestdisServer.Commands.DispatcherTest do
  use ExUnit.Case, async: false

  alias RestdisServer.Commands.Dispatcher

  setup do
    tenant_id = "tenant_dispatcher_#{System.unique_integer([:positive])}"
    on_exit(fn -> Restdis.Cache.flush_tenant(tenant_id) end)
    {:ok, tenant_id: tenant_id}
  end

  defp state(tenant_id), do: %{authenticated?: true, tenant_id: tenant_id, buffer: <<>>}

  test "dispatch/2 with an empty command list replies with an error" do
    {reply, state} = Dispatcher.dispatch(%{authenticated?: true}, [])
    assert IO.iodata_to_binary(reply) == "-ERR empty command\r\n"
    assert state == %{authenticated?: true}
  end

  test "dispatch/2 lowercases the command name", %{tenant_id: tenant_id} do
    {reply, _state} = Dispatcher.dispatch(state(tenant_id), ["ping"])
    assert IO.iodata_to_binary(reply) == "+PONG\r\n"
  end

  test "dispatch/2 routes an unknown command to an error reply", %{tenant_id: tenant_id} do
    {reply, _state} = Dispatcher.dispatch(state(tenant_id), ["NOPE", "arg"])
    assert IO.iodata_to_binary(reply) == "-ERR unknown command 'NOPE'\r\n"
  end

  test "dispatch/2 routes SET", %{tenant_id: tenant_id} do
    {reply, _state} = Dispatcher.dispatch(state(tenant_id), ["SET", "mykey", "myvalue"])
    assert IO.iodata_to_binary(reply) == "+OK\r\n"
  end

  test "dispatch/2 routes GET", %{tenant_id: tenant_id} do
    Dispatcher.dispatch(state(tenant_id), ["SET", "mykey", "myvalue"])
    {reply, _state} = Dispatcher.dispatch(state(tenant_id), ["GET", "mykey"])
    assert IO.iodata_to_binary(reply) == "$7\r\nmyvalue\r\n"
  end

  test "dispatch/2 routes MGET", %{tenant_id: tenant_id} do
    Dispatcher.dispatch(state(tenant_id), ["SET", "mykey", "myvalue"])
    {reply, _state} = Dispatcher.dispatch(state(tenant_id), ["MGET", "mykey", "missing"])
    assert IO.iodata_to_binary(reply) == "*2\r\n$7\r\nmyvalue\r\n$-1\r\n"
  end

  test "dispatch/2 routes DEL", %{tenant_id: tenant_id} do
    Dispatcher.dispatch(state(tenant_id), ["SET", "mykey", "myvalue"])
    {reply, _state} = Dispatcher.dispatch(state(tenant_id), ["DEL", "mykey"])
    assert IO.iodata_to_binary(reply) == ":1\r\n"
  end

  test "dispatch/2 routes TTL", %{tenant_id: tenant_id} do
    Dispatcher.dispatch(state(tenant_id), ["SET", "mykey", "myvalue"])
    {reply, _state} = Dispatcher.dispatch(state(tenant_id), ["TTL", "mykey"])
    assert IO.iodata_to_binary(reply) == ":-1\r\n"
  end

  test "dispatch/2 routes EXISTS", %{tenant_id: tenant_id} do
    Dispatcher.dispatch(state(tenant_id), ["SET", "mykey", "myvalue"])
    {reply, _state} = Dispatcher.dispatch(state(tenant_id), ["EXISTS", "mykey", "missing"])
    assert IO.iodata_to_binary(reply) == ":1\r\n"
  end

  test "dispatch/2 routes INCR", %{tenant_id: tenant_id} do
    {reply, _state} = Dispatcher.dispatch(state(tenant_id), ["INCR", "counter"])
    assert IO.iodata_to_binary(reply) == ":1\r\n"
  end

  test "dispatch/2 routes DECR", %{tenant_id: tenant_id} do
    {reply, _state} = Dispatcher.dispatch(state(tenant_id), ["DECR", "counter"])
    assert IO.iodata_to_binary(reply) == ":-1\r\n"
  end

  test "dispatch/2 routes INCRBY", %{tenant_id: tenant_id} do
    {reply, _state} = Dispatcher.dispatch(state(tenant_id), ["INCRBY", "counter", "5"])
    assert IO.iodata_to_binary(reply) == ":5\r\n"
  end

  test "dispatch/2 routes DECRBY", %{tenant_id: tenant_id} do
    {reply, _state} = Dispatcher.dispatch(state(tenant_id), ["DECRBY", "counter", "5"])
    assert IO.iodata_to_binary(reply) == ":-5\r\n"
  end

  test "dispatch/2 routes EXPIRE", %{tenant_id: tenant_id} do
    Dispatcher.dispatch(state(tenant_id), ["SET", "mykey", "myvalue"])
    {reply, _state} = Dispatcher.dispatch(state(tenant_id), ["EXPIRE", "mykey", "60"])
    assert IO.iodata_to_binary(reply) == ":1\r\n"
  end

  test "dispatch/2 routes PEXPIRE", %{tenant_id: tenant_id} do
    Dispatcher.dispatch(state(tenant_id), ["SET", "mykey", "myvalue"])
    {reply, _state} = Dispatcher.dispatch(state(tenant_id), ["PEXPIRE", "mykey", "60000"])
    assert IO.iodata_to_binary(reply) == ":1\r\n"
  end

  test "dispatch/2 routes PERSIST", %{tenant_id: tenant_id} do
    {reply, _state} = Dispatcher.dispatch(state(tenant_id), ["PERSIST", "mykey"])
    assert IO.iodata_to_binary(reply) == ":0\r\n"
  end

  test "dispatch/2 routes SETNX", %{tenant_id: tenant_id} do
    {reply, _state} = Dispatcher.dispatch(state(tenant_id), ["SETNX", "mykey", "myvalue"])
    assert IO.iodata_to_binary(reply) == ":1\r\n"
  end

  test "dispatch/2 routes GETSET", %{tenant_id: tenant_id} do
    {reply, _state} = Dispatcher.dispatch(state(tenant_id), ["GETSET", "mykey", "myvalue"])
    assert IO.iodata_to_binary(reply) == "$-1\r\n"
  end

  test "dispatch/2 routes GETDEL", %{tenant_id: tenant_id} do
    Dispatcher.dispatch(state(tenant_id), ["SET", "mykey", "myvalue"])
    {reply, _state} = Dispatcher.dispatch(state(tenant_id), ["GETDEL", "mykey"])
    assert IO.iodata_to_binary(reply) == "$7\r\nmyvalue\r\n"
  end

  test "dispatch/2 routes APPEND", %{tenant_id: tenant_id} do
    {reply, _state} = Dispatcher.dispatch(state(tenant_id), ["APPEND", "mykey", "hello"])
    assert IO.iodata_to_binary(reply) == ":5\r\n"
  end

  test "dispatch/2 routes STRLEN", %{tenant_id: tenant_id} do
    Dispatcher.dispatch(state(tenant_id), ["SET", "mykey", "myvalue"])
    {reply, _state} = Dispatcher.dispatch(state(tenant_id), ["STRLEN", "mykey"])
    assert IO.iodata_to_binary(reply) == ":7\r\n"
  end

  test "dispatch/2 routes RENAME", %{tenant_id: tenant_id} do
    Dispatcher.dispatch(state(tenant_id), ["SET", "src", "hello"])
    {reply, _state} = Dispatcher.dispatch(state(tenant_id), ["RENAME", "src", "dst"])
    assert IO.iodata_to_binary(reply) == "+OK\r\n"
  end

  test "dispatch/2 routes RENAMENX", %{tenant_id: tenant_id} do
    Dispatcher.dispatch(state(tenant_id), ["SET", "src", "hello"])
    {reply, _state} = Dispatcher.dispatch(state(tenant_id), ["RENAMENX", "src", "dst"])
    assert IO.iodata_to_binary(reply) == ":1\r\n"
  end

  test "dispatch/2 routes DBSIZE", %{tenant_id: tenant_id} do
    {reply, _state} = Dispatcher.dispatch(state(tenant_id), ["DBSIZE"])
    assert IO.iodata_to_binary(reply) =~ ~r/^:\d+\r\n$/
  end

  test "dispatch/2 routes COPY", %{tenant_id: tenant_id} do
    Dispatcher.dispatch(state(tenant_id), ["SET", "src", "hello"])
    {reply, _state} = Dispatcher.dispatch(state(tenant_id), ["COPY", "src", "dst"])
    assert IO.iodata_to_binary(reply) == ":1\r\n"
  end

  test "dispatch/2 rejects unauthenticated connections for auth-required commands" do
    {reply, _state} = Dispatcher.dispatch(%{authenticated?: false}, ["GET", "mykey"])
    assert IO.iodata_to_binary(reply) == "-NOAUTH Authentication required\r\n"
  end

  test "dispatch/2 allows PING without authentication" do
    {reply, _state} = Dispatcher.dispatch(%{authenticated?: false}, ["PING"])
    assert IO.iodata_to_binary(reply) == "+PONG\r\n"
  end
end
