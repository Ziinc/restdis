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
end
