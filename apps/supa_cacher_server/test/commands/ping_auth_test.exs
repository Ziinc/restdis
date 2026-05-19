defmodule SupaCacherServer.Commands.PingAuthTest do
  use ExUnit.Case, async: true

  alias SupaCacherServer.Commands.Dispatcher
  alias SupaCacherServer.TenantStore.InMemory

  setup do
    InMemory.seed([
      %{
        api_key: "sk_test",
        tenant_id: "tenant-1",
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

  describe "PING" do
    test "responds PONG before auth" do
      {reply, _state} = Dispatcher.dispatch(unauthed_state(), ["PING"])
      assert IO.iodata_to_binary(reply) == "+PONG\r\n"
    end

    test "responds with message when arg given" do
      {reply, _} = Dispatcher.dispatch(unauthed_state(), ["PING", "hello"])
      assert IO.iodata_to_binary(reply) == "$5\r\nhello\r\n"
    end
  end

  describe "AUTH" do
    test "authenticates with valid api key" do
      {reply, new_state} = Dispatcher.dispatch(unauthed_state(), ["AUTH", "sk_test"])
      assert IO.iodata_to_binary(reply) == "+OK\r\n"
      assert new_state.authenticated? == true
      assert new_state.tenant_id == "tenant-1"
    end

    test "rejects invalid api key" do
      {reply, state} = Dispatcher.dispatch(unauthed_state(), ["AUTH", "bad_key"])
      assert IO.iodata_to_binary(reply) =~ "WRONGPASS"
      assert state.authenticated? == false
    end
  end

  describe "command gating" do
    test "GET returns NOAUTH before auth" do
      wire_key = "pgrst:t:users:12345"
      {reply, _} = Dispatcher.dispatch(unauthed_state(), ["GET", wire_key])
      assert IO.iodata_to_binary(reply) =~ "NOAUTH"
    end
  end
end
