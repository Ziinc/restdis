defmodule RestdisServer.Commands.HelloTest do
  use ExUnit.Case, async: true

  alias RestdisServer.Commands.Dispatcher
  alias RestdisServer.TenantStore.InMemory

  setup do
    InMemory.seed([
      %{
        api_key: "sk_hello",
        tenant_id: "tenant-hello",
        default_ttl_s: 60,
        persist_cap: 50_000,
        pgrst_base_url: "http://localhost:3000",
        pgrst_api_key: "service_key",
        replica_url: nil
      }
    ])

    on_exit(fn -> InMemory.clear() end)
    :ok
  end

  defp unauthed_state, do: %{authenticated?: false, tenant_id: nil, buffer: <<>>}
  defp authed_state, do: %{authenticated?: true, tenant_id: "tenant-hello", buffer: <<>>}

  defp reply(state, command) do
    {reply, new_state} = Dispatcher.dispatch(state, command)
    {IO.iodata_to_binary(reply), new_state}
  end

  test "HELLO 3 before auth answers NOPROTO so RESP3 clients fall back to RESP2" do
    {reply, state} = reply(unauthed_state(), ["HELLO", "3", "AUTH", "default", "sk_hello"])
    assert reply =~ ~r/^-NOPROTO /
    assert state.authenticated? == false
  end

  test "HELLO with a non-integer protocol version answers ERR" do
    {reply, _state} = reply(unauthed_state(), ["HELLO", "two"])
    assert reply == "-ERR Protocol version is not an integer or out of range\r\n"
  end

  test "HELLO 2 AUTH authenticates the connection and binds the tenant" do
    {reply, state} = reply(unauthed_state(), ["HELLO", "2", "AUTH", "default", "sk_hello"])
    assert reply =~ ~r/^\*14\r\n\$6\r\nserver\r\n\$7\r\nrestdis\r\n/
    assert reply =~ "$5\r\nproto\r\n:2\r\n"
    assert state.authenticated? == true
    assert state.tenant_id == "tenant-hello"
  end

  test "HELLO 2 AUTH with an invalid API key answers WRONGPASS" do
    {reply, state} = reply(unauthed_state(), ["HELLO", "2", "AUTH", "default", "nope"])
    assert reply =~ ~r/^-WRONGPASS /
    assert state.authenticated? == false
  end

  test "HELLO 2 AUTH with an invalid API key on an authenticated connection answers WRONGPASS" do
    {reply, state} = reply(authed_state(), ["HELLO", "2", "AUTH", "default", "nope"])
    assert reply =~ ~r/^-WRONGPASS /
    assert state == authed_state()
  end

  test "HELLO with any protocol version other than 2 answers NOPROTO" do
    {reply, _state} = reply(unauthed_state(), ["HELLO", "1"])
    assert reply =~ ~r/^-NOPROTO /
  end

  test "HELLO without AUTH on an unauthenticated connection answers NOAUTH" do
    {reply, _state} = reply(unauthed_state(), ["HELLO", "2"])
    assert reply =~ ~r/^-NOAUTH /
  end

  test "HELLO on an authenticated connection returns the server info" do
    {reply, state} = reply(authed_state(), ["HELLO"])
    assert reply =~ ~r/^\*14\r\n/
    assert reply =~ "$7\r\nmodules\r\n*0\r\n"
    assert state == authed_state()
  end

  test "HELLO options are case-insensitive" do
    {_reply, state} = reply(unauthed_state(), ["hello", "2", "auth", "default", "sk_hello"])
    assert state.authenticated? == true
  end

  test "HELLO accepts and ignores SETNAME" do
    {reply, _state} = reply(authed_state(), ["HELLO", "2", "SETNAME", "worker-1"])
    assert reply =~ ~r/^\*14\r\n/
  end

  test "HELLO AUTH without a password answers a syntax error" do
    {reply, _state} = reply(unauthed_state(), ["HELLO", "2", "AUTH", "default"])
    assert reply == "-ERR Syntax error in HELLO option 'AUTH'\r\n"
  end
end
