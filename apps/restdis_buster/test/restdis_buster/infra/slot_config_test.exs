defmodule RestdisBuster.Infra.SlotConfigTest do
  use ExUnit.Case, async: false

  alias RestdisBuster.Infra.SlotConfig

  setup do
    original = Application.get_env(:restdis_buster, :replication_connection)
    on_exit(fn -> Application.put_env(:restdis_buster, :replication_connection, original) end)
    :ok
  end

  defp put_conn(opts), do: Application.put_env(:restdis_buster, :replication_connection, opts)

  test "keyword options are returned unchanged" do
    put_conn(hostname: "localhost", database: "db", username: "u")

    assert SlotConfig.replication_conn_opts() == [
             hostname: "localhost",
             database: "db",
             username: "u"
           ]
  end

  test "a :url option is expanded into connection options" do
    put_conn(url: "ecto://alice:s3cret@db.internal:5433/restdis", pool_size: 1)

    opts = SlotConfig.replication_conn_opts()

    assert opts[:hostname] == "db.internal"
    assert opts[:port] == 5433
    assert opts[:username] == "alice"
    assert opts[:password] == "s3cret"
    assert opts[:database] == "restdis"
    assert opts[:pool_size] == 1
    refute Keyword.has_key?(opts, :url)
  end

  test "a :url without port or credentials omits those options" do
    put_conn(url: "postgres://db.internal/restdis")

    opts = SlotConfig.replication_conn_opts()

    assert opts[:hostname] == "db.internal"
    assert opts[:database] == "restdis"
    refute Keyword.has_key?(opts, :port)
    refute Keyword.has_key?(opts, :username)
    refute Keyword.has_key?(opts, :password)
  end

  test "percent-encoded credentials are decoded" do
    put_conn(url: "postgres://a%40b:p%40ss@db.internal/restdis")

    opts = SlotConfig.replication_conn_opts()

    assert opts[:username] == "a@b"
    assert opts[:password] == "p@ss"
  end

  test "explicit options win over the url" do
    put_conn(url: "postgres://db.internal/restdis", hostname: "override")

    assert SlotConfig.replication_conn_opts()[:hostname] == "override"
  end
end
