defmodule RestdisServer.ListenerTest do
  use ExUnit.Case, async: true

  alias RestdisServer.Listener

  test "atoms are passed through" do
    assert Listener.parse_ip(:loopback) == :loopback
    assert Listener.parse_ip(:any) == :any
  end

  test "tuples are passed through" do
    assert Listener.parse_ip({127, 0, 0, 1}) == {127, 0, 0, 1}
  end

  test "IPv4 strings are parsed into address tuples" do
    assert Listener.parse_ip("0.0.0.0") == {0, 0, 0, 0}
    assert Listener.parse_ip("10.1.2.3") == {10, 1, 2, 3}
  end

  test "IPv6 strings are parsed into address tuples" do
    assert Listener.parse_ip("::1") == {0, 0, 0, 0, 0, 0, 0, 1}
  end

  test "unparseable strings fall back to loopback" do
    assert Listener.parse_ip("not-an-ip") == :loopback
  end
end
