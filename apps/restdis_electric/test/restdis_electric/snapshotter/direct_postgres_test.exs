defmodule RestdisElectric.Snapshotter.DirectPostgresTest do
  use ExUnit.Case, async: false

  alias RestdisElectric.Definition
  alias RestdisElectric.Snapshotter.DirectPostgres
  alias RestdisElectric.TestUtils

  @direct_pg_url "postgres://postgres:postgres@#{System.get_env("POSTGRES_HOSTNAME", "localhost")}:5432/restdis_test"

  setup do
    {:ok, conn} = Postgrex.start_link(DirectPostgres.connect_opts(@direct_pg_url))

    Postgrex.query!(conn, "DROP TABLE IF EXISTS direct_pg_snapshot_widgets", [])

    Postgrex.query!(
      conn,
      "CREATE TABLE direct_pg_snapshot_widgets (id integer PRIMARY KEY, name text)",
      []
    )

    Postgrex.query!(
      conn,
      "INSERT INTO direct_pg_snapshot_widgets (id, name) VALUES (1, 'a'), (2, 'b')",
      []
    )

    on_exit(fn ->
      {:ok, conn} = Postgrex.start_link(DirectPostgres.connect_opts(@direct_pg_url))
      Postgrex.query!(conn, "DROP TABLE IF EXISTS direct_pg_snapshot_widgets", [])
    end)

    TestUtils.put_table("public.direct_pg_snapshot_widgets", %{
      columns: ["id", "name"],
      primary_key: ["id"],
      replica_identity: :full
    })

    :ok
  end

  describe "connect_opts/1" do
    test "parses a postgres:// URL into Postgrex connection options" do
      opts = DirectPostgres.connect_opts("postgres://user:pass@example.com:6543/mydb")

      assert opts[:hostname] == "example.com"
      assert opts[:port] == 6543
      assert opts[:username] == "user"
      assert opts[:password] == "pass"
      assert opts[:database] == "mydb"
    end
  end

  describe "snapshot/3" do
    test "streams every row and returns a snapshot descriptor" do
      definition = %Definition{
        tenant_id: "t1",
        schema: "public",
        table: "direct_pg_snapshot_widgets",
        columns: nil,
        params: %{}
      }

      tenant_config = %{direct_pg_url: @direct_pg_url}
      test_pid = self()

      assert {:ok, descriptor} =
               DirectPostgres.snapshot(tenant_config, definition, fn rows ->
                 send(test_pid, {:page, rows})
               end)

      assert_received {:page, rows}

      assert Enum.sort_by(rows, & &1["id"]) == [
               %{"id" => 1, "name" => "a"},
               %{"id" => 2, "name" => "b"}
             ]

      assert %{xmin: _, xmax: _, xip_list: _} = descriptor
    end
  end

  test "stream/3 implements the Snapshotter behaviour, discarding the descriptor" do
    definition = %Definition{
      tenant_id: "t1",
      schema: "public",
      table: "direct_pg_snapshot_widgets",
      columns: nil,
      params: %{}
    }

    tenant_config = %{direct_pg_url: @direct_pg_url}
    test_pid = self()

    assert :ok =
             DirectPostgres.stream(tenant_config, definition, fn rows ->
               send(test_pid, {:page, rows})
             end)

    assert_received {:page, _rows}
  end

  describe "snapshot_descriptor/2" do
    test "returns a descriptor without paging through the table's rows" do
      definition = %Definition{
        tenant_id: "t1",
        schema: "public",
        table: "direct_pg_snapshot_widgets",
        columns: nil,
        params: %{}
      }

      tenant_config = %{direct_pg_url: @direct_pg_url}

      assert {:ok, %{xmin: _, xmax: _, xip_list: _}} =
               DirectPostgres.snapshot_descriptor(tenant_config, definition)
    end
  end
end
