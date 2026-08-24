defmodule SupaCacherServer.RESP.HandlerSocketTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, pid} =
      ThousandIsland.start_link(
        port: 0,
        handler_module: SupaCacherServer.RESP.Handler,
        transport_options: [ip: :loopback]
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)

    {:ok, port: port}
  end

  defp connect(port) do
    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw], 1_000)

    socket
  end

  test "PING over a real socket answers PONG", %{port: port} do
    socket = connect(port)

    :ok = :gen_tcp.send(socket, "*1\r\n$4\r\nPING\r\n")

    assert {:ok, "+PONG\r\n"} = :gen_tcp.recv(socket, 0, 1_000)
  end

  test "an unauthenticated command answers NOAUTH", %{port: port} do
    socket = connect(port)

    :ok = :gen_tcp.send(socket, "*2\r\n$3\r\nGET\r\n$1\r\nk\r\n")

    assert {:ok, "-NOAUTH" <> _} = :gen_tcp.recv(socket, 0, 1_000)
  end

  test "a command split across packets is answered once complete", %{port: port} do
    socket = connect(port)

    :ok = :gen_tcp.send(socket, "*1\r\n$4\r\nPI")
    :ok = :gen_tcp.send(socket, "NG\r\n")

    assert {:ok, "+PONG\r\n"} = :gen_tcp.recv(socket, 0, 1_000)
  end
end
