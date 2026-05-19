defmodule SupaCacherServer.HTTP.Plug.CacheHeaders do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts), do: conn

  @spec put_cache_miss(Plug.Conn.t(), pos_integer()) :: Plug.Conn.t()
  def put_cache_miss(conn, ttl_s) do
    conn
    |> put_resp_header("sc-cache", "MISS")
    |> put_resp_header("sc-cache-ttl", Integer.to_string(ttl_s))
  end

  @spec put_cache_hit(Plug.Conn.t(), non_neg_integer(), String.t()) :: Plug.Conn.t()
  def put_cache_hit(conn, ttl_remaining_s, rewarm \\ "none") do
    conn
    |> put_resp_header("sc-cache", "HIT")
    |> put_resp_header("sc-cache-ttl", Integer.to_string(ttl_remaining_s))
    |> put_resp_header("sc-cache-rewarm", rewarm)
  end

  @spec put_policy_ok(Plug.Conn.t(), pos_integer()) :: Plug.Conn.t()
  def put_policy_ok(conn, ttl_s) do
    conn
    |> put_resp_header("sc-cache-ttl", Integer.to_string(ttl_s))
    |> put_resp_header("sc-cache-rewarm", "deferred")
  end
end
