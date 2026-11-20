defmodule Restdis.Wal.InstanceConfigTest do
  use ExUnit.Case, async: true

  alias Restdis.Wal.InstanceConfig

  defp replication(opts) do
    name = :"wal_config_#{System.unique_integer([:positive])}"
    :ok = InstanceConfig.put(name, repo: SomeRepo, replication: opts)
    InstanceConfig.fetch!(name).replication
  end

  test "defaults everything but the repo" do
    :ok = InstanceConfig.put(:wal_config_defaults, repo: SomeRepo)

    assert InstanceConfig.fetch!(:wal_config_defaults) == %{
             repo: SomeRepo,
             prefix: "restdis",
             slot_name: "restdis_slot",
             publication: "restdis_pub",
             replication: [],
             az: "local",
             handler: nil,
             telemetry_prefix: [:restdis],
             topology: :syn,
             on_takeover: nil
           }
  end

  test "requires a repo" do
    assert_raise KeyError, fn -> InstanceConfig.put(:wal_config_no_repo, []) end
  end

  test "fetch!/1 raises for an instance that was never started" do
    assert_raise ArgumentError, ~r/not started/, fn -> InstanceConfig.fetch!(:never_started) end
  end

  test "keyword options are returned unchanged" do
    assert replication(hostname: "localhost", database: "db", username: "u") == [
             hostname: "localhost",
             database: "db",
             username: "u"
           ]
  end

  test "a :url option is expanded into connection options" do
    opts = replication(url: "ecto://alice:s3cret@db.internal:5433/restdis", pool_size: 1)

    assert opts[:hostname] == "db.internal"
    assert opts[:port] == 5433
    assert opts[:username] == "alice"
    assert opts[:password] == "s3cret"
    assert opts[:database] == "restdis"
    assert opts[:pool_size] == 1
    refute Keyword.has_key?(opts, :url)
  end

  test "a :url without port or credentials omits those options" do
    opts = replication(url: "postgres://db.internal/restdis")

    assert opts[:hostname] == "db.internal"
    assert opts[:database] == "restdis"
    refute Keyword.has_key?(opts, :port)
    refute Keyword.has_key?(opts, :username)
    refute Keyword.has_key?(opts, :password)
  end

  test "percent-encoded credentials are decoded" do
    opts = replication(url: "postgres://a%40b:p%40ss@db.internal/restdis")

    assert opts[:username] == "a@b"
    assert opts[:password] == "p@ss"
  end

  test "a :url with a username but no password omits the password" do
    opts = replication(url: "postgres://alice@db.internal/restdis")

    assert opts[:username] == "alice"
    refute Keyword.has_key?(opts, :password)
  end

  test "a :url with a root path (no database) omits the database" do
    opts = replication(url: "postgres://db.internal/")

    assert opts[:hostname] == "db.internal"
    refute Keyword.has_key?(opts, :database)
  end

  test "a :url with no path at all omits the database" do
    opts = replication(url: "postgres://db.internal")

    assert opts[:hostname] == "db.internal"
    refute Keyword.has_key?(opts, :database)
  end

  test "explicit options win over the url" do
    assert replication(url: "postgres://db.internal/restdis", hostname: "override")[:hostname] ==
             "override"
  end
end
