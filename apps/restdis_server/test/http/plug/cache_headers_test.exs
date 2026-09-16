defmodule RestdisServer.HTTP.Plug.CacheHeadersTest do
  use ExUnit.Case, async: true

  alias RestdisServer.HTTP.Plug.CacheHeaders

  defp conn, do: Plug.Test.conn(:get, "/")

  test "init/1 returns opts unchanged" do
    assert CacheHeaders.init(:opts) == :opts
  end

  test "call/2 returns the conn unchanged" do
    conn = conn()
    assert CacheHeaders.call(conn, []) == conn
  end

  test "put_cache_miss/2 sets the MISS headers" do
    result = CacheHeaders.put_cache_miss(conn(), 60)

    assert Plug.Conn.get_resp_header(result, "sc-cache") == ["MISS"]
    assert Plug.Conn.get_resp_header(result, "sc-cache-ttl") == ["60"]
  end

  test "put_cache_bypass/1 sets the BYPASS header" do
    result = CacheHeaders.put_cache_bypass(conn())

    assert Plug.Conn.get_resp_header(result, "sc-cache") == ["BYPASS"]
  end

  test "put_cache_hit/2 defaults the rewarm header to \"none\"" do
    result = CacheHeaders.put_cache_hit(conn(), 30)

    assert Plug.Conn.get_resp_header(result, "sc-cache") == ["HIT"]
    assert Plug.Conn.get_resp_header(result, "sc-cache-ttl") == ["30"]
    assert Plug.Conn.get_resp_header(result, "sc-cache-rewarm") == ["none"]
  end

  test "put_cache_hit/3 sets the given rewarm header" do
    result = CacheHeaders.put_cache_hit(conn(), 30, "scheduled")

    assert Plug.Conn.get_resp_header(result, "sc-cache-rewarm") == ["scheduled"]
  end

  test "put_policy_ok/2 sets the ttl and a deferred rewarm header" do
    result = CacheHeaders.put_policy_ok(conn(), 120)

    assert Plug.Conn.get_resp_header(result, "sc-cache-ttl") == ["120"]
    assert Plug.Conn.get_resp_header(result, "sc-cache-rewarm") == ["deferred"]
  end
end
