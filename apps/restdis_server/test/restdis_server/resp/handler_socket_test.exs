defmodule RestdisServer.RESP.HandlerSocketTest do
  use ExUnit.Case, async: true

  import RestdisServer.TestUtils

  setup do
    {:ok, port: start_resp_listener()}
  end

  defp assert_protocol_error_and_close(socket, message) do
    expected = "-ERR Protocol error: #{message}\r\n"
    assert {:ok, ^expected} = :gen_tcp.recv(socket, 0, 1_000)
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
  end

  test "PING over a real socket answers PONG", %{port: port} do
    socket = connect_resp(port)

    :ok = :gen_tcp.send(socket, "*1\r\n$4\r\nPING\r\n")

    assert {:ok, "+PONG\r\n"} = :gen_tcp.recv(socket, 0, 1_000)
  end

  test "an unauthenticated command answers NOAUTH", %{port: port} do
    socket = connect_resp(port)

    :ok = :gen_tcp.send(socket, "*2\r\n$3\r\nGET\r\n$1\r\nk\r\n")

    assert {:ok, "-NOAUTH" <> _} = :gen_tcp.recv(socket, 0, 1_000)
  end

  test "a command split across packets is answered once complete", %{port: port} do
    socket = connect_resp(port)

    :ok = :gen_tcp.send(socket, "*1\r\n$4\r\nPI")
    :ok = :gen_tcp.send(socket, "NG\r\n")

    assert {:ok, "+PONG\r\n"} = :gen_tcp.recv(socket, 0, 1_000)
  end

  test "malformed input replies with a protocol error and closes the connection", %{port: port} do
    socket = connect_resp(port)

    :ok = :gen_tcp.send(socket, "*1\r\n$notanumber\r\n")

    assert {:ok, "-ERR Protocol error" <> _} = :gen_tcp.recv(socket, 0, 1_000)
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
  end

  test "*-1 and *0 are ignored without a reply and later commands still run", %{port: port} do
    socket = connect_resp(port)

    :ok = :gen_tcp.send(socket, "*-1\r\n*0\r\n*1\r\n$4\r\nPING\r\n")

    assert {:ok, "+PONG\r\n"} = :gen_tcp.recv(socket, 0, 1_000)
  end

  test "an array count below -1 replies with a protocol error and closes", %{port: port} do
    socket = connect_resp(port)

    :ok = :gen_tcp.send(socket, "*-2\r\n")

    assert_protocol_error_and_close(socket, "invalid multibulk length")
  end

  test "a bulk length below -1 replies with a protocol error and closes", %{port: port} do
    socket = connect_resp(port)

    :ok = :gen_tcp.send(socket, "*1\r\n$-5\r\n")

    assert_protocol_error_and_close(socket, "invalid bulk length")
  end

  test "a nil command name answers ERR and keeps the connection open", %{port: port} do
    socket = connect_resp(port)

    :ok = :gen_tcp.send(socket, "*1\r\n$-1\r\n")
    assert {:ok, "-ERR " <> _} = :gen_tcp.recv(socket, 0, 1_000)

    :ok = :gen_tcp.send(socket, "*1\r\n$4\r\nPING\r\n")
    assert {:ok, "+PONG\r\n"} = :gen_tcp.recv(socket, 0, 1_000)
  end

  test "a nil argument answers ERR", %{port: port} do
    socket = connect_resp(port)

    :ok = :gen_tcp.send(socket, "*2\r\n$4\r\nPING\r\n$-1\r\n")

    assert {:ok, "-ERR " <> _} = :gen_tcp.recv(socket, 0, 1_000)
  end

  test "before AUTH an array of more than 10 elements is rejected and closes", %{port: port} do
    socket = connect_resp(port)

    :ok = :gen_tcp.send(socket, "*11\r\n")

    assert_protocol_error_and_close(socket, "unauthenticated multibulk length")
  end

  test "before AUTH a bulk longer than 16384 bytes is rejected and closes", %{port: port} do
    socket = connect_resp(port)

    :ok = :gen_tcp.send(socket, "*2\r\n$4\r\nPING\r\n$16385\r\n")

    assert_protocol_error_and_close(socket, "unauthenticated bulk length")
  end

  test "an inline line beyond 64KB without CRLF is rejected and closes", %{port: port} do
    socket = connect_resp(port)

    :ok = :gen_tcp.send(socket, :binary.copy("a", 64 * 1024 + 1))

    assert_protocol_error_and_close(socket, "too big inline request")
  end
end
