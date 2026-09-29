defmodule RestdisServer.RESP.HandlerAuthenticatedLimitsTest do
  use ExUnit.Case, async: false

  import RestdisServer.TestUtils

  alias RestdisServer.TenantConfig
  alias RestdisServer.TenantStore.InMemory

  setup do
    tenant_id = "tenant_resp_limits_#{System.unique_integer([:positive])}"
    api_key = "key-#{tenant_id}"

    InMemory.seed([
      %{
        tenant_id: tenant_id,
        api_key: api_key,
        default_ttl_s: 60,
        persist_cap: 10,
        pgrst_base_url: "http://localhost",
        pgrst_api_key: "pgrst",
        replica_url: nil
      }
    ])

    TenantConfig.invalidate(tenant_id)
    on_exit(fn -> InMemory.clear() end)

    socket = connect_resp(start_resp_listener())
    auth = "*2\r\n$4\r\nAUTH\r\n$#{byte_size(api_key)}\r\n#{api_key}\r\n"
    :ok = :gen_tcp.send(socket, auth)
    assert {:ok, "+OK\r\n"} = :gen_tcp.recv(socket, 0, 1_000)

    {:ok, socket: socket}
  end

  test "a 16MB bulk fed in 64KB chunks is answered within 3 seconds", %{socket: socket} do
    chunk = :binary.copy("a", 64 * 1024)
    chunks = 256
    started = System.monotonic_time(:millisecond)

    :ok = :gen_tcp.send(socket, "*2\r\n$4\r\nNOPE\r\n$#{chunks * byte_size(chunk)}\r\n")
    for _ <- 1..chunks, do: :ok = :gen_tcp.send(socket, chunk)
    :ok = :gen_tcp.send(socket, "\r\n")

    assert {:ok, "-ERR unknown command 'NOPE'\r\n"} = :gen_tcp.recv(socket, 0, 30_000)
    assert System.monotonic_time(:millisecond) - started < 3_000
  end

  test "after AUTH a bulk longer than 512MB is rejected and closes", %{socket: socket} do
    :ok = :gen_tcp.send(socket, "*2\r\n$4\r\nPING\r\n$#{512 * 1024 * 1024 + 1}\r\n")

    assert {:ok, "-ERR Protocol error: invalid bulk length\r\n"} =
             :gen_tcp.recv(socket, 0, 1_000)

    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
  end

  test "after AUTH an array of more than 1048576 elements is rejected and closes", %{
    socket: socket
  } do
    :ok = :gen_tcp.send(socket, "*#{1_048_577}\r\n")

    assert {:ok, "-ERR Protocol error: invalid multibulk length\r\n"} =
             :gen_tcp.recv(socket, 0, 1_000)

    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
  end
end
