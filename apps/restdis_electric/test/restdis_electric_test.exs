defmodule RestdisElectricTest do
  use ExUnit.Case, async: false

  alias RestdisElectric.Handle
  alias RestdisElectric.Message
  alias RestdisElectric.Snapshotter.DirectPostgres
  alias RestdisElectric.TestUtils
  alias RestdisElectric.WAL

  @tenant_config %{pgrst_base_url: "http://origin", pgrst_api_key: "key"}

  setup do
    TestUtils.put_table("public.widgets", %{
      columns: ["id", "name"],
      primary_key: ["id"],
      replica_identity: :full
    })

    :ok
  end

  test "subscribing from -1 snapshots the table and returns every row as an insert" do
    tenant_id = TestUtils.tenant_id()

    TestUtils.put_stub_rows("widgets", [
      %{"id" => 1, "name" => "a"},
      %{"id" => 2, "name" => "b"}
    ])

    assert {:ok, result} =
             RestdisElectric.subscribe(tenant_id, @tenant_config, %{
               "table" => "widgets",
               "offset" => "-1"
             })

    assert Enum.count(result.messages) == 2
    assert Enum.all?(result.messages, &(&1.operation == :insert))
    assert result.up_to_date
    assert is_binary(result.handle)
  end

  test "resuming with a valid handle returns only messages after the given offset" do
    tenant_id = TestUtils.tenant_id()
    TestUtils.put_stub_rows("widgets", [%{"id" => 1, "name" => "a"}])

    {:ok, first} =
      RestdisElectric.subscribe(tenant_id, @tenant_config, %{
        "table" => "widgets",
        "offset" => "-1"
      })

    assert {:ok, resumed} =
             RestdisElectric.subscribe(tenant_id, @tenant_config, %{
               "table" => "widgets",
               "handle" => first.handle,
               "offset" => RestdisElectric.Offset.encode(first.offset)
             })

    assert resumed.messages == []
    assert resumed.handle == first.handle
  end

  test "an invalid offset is rejected" do
    assert {:error, {:invalid_offset, "bogus"}} =
             RestdisElectric.subscribe(TestUtils.tenant_id(), @tenant_config, %{
               "table" => "widgets",
               "offset" => "bogus"
             })
  end

  test "resuming without a handle is rejected" do
    assert {:error, {:missing_handle, nil}} =
             RestdisElectric.subscribe(TestUtils.tenant_id(), @tenant_config, %{
               "table" => "widgets",
               "offset" => "0_inf"
             })
  end

  test "resuming with a handle for a different definition returns must_refetch" do
    tenant_id = TestUtils.tenant_id()
    {:ok, other} = RestdisElectric.Definition.new("someone-else", %{"table" => "widgets"})
    stale_handle = Handle.new(other)

    assert {:error, :must_refetch, new_handle} =
             RestdisElectric.subscribe(tenant_id, @tenant_config, %{
               "table" => "widgets",
               "handle" => stale_handle,
               "offset" => "0_inf"
             })

    assert is_binary(new_handle)
  end

  test "resuming with a handle whose log was evicted returns must_refetch" do
    tenant_id = TestUtils.tenant_id()
    TestUtils.put_stub_rows("widgets", [])

    {:ok, first} =
      RestdisElectric.subscribe(tenant_id, @tenant_config, %{
        "table" => "widgets",
        "offset" => "-1"
      })

    RestdisElectric.delete_shape(tenant_id, first.handle)

    assert {:error, :must_refetch, _new_handle} =
             RestdisElectric.subscribe(tenant_id, @tenant_config, %{
               "table" => "widgets",
               "handle" => first.handle,
               "offset" => "0_inf"
             })
  end

  test "a WAL change to a table with an active shape is appended live" do
    tenant_id = TestUtils.tenant_id()
    TestUtils.put_stub_rows("widgets", [%{"id" => 1, "name" => "a"}])

    {:ok, subscribed} =
      RestdisElectric.subscribe(tenant_id, @tenant_config, %{
        "table" => "widgets",
        "offset" => "-1"
      })

    :ok =
      WAL.ingest(%{
        tenant_id: tenant_id,
        schema: "public",
        table: "widgets",
        op: :update,
        pk: 1,
        new_row: %{"id" => 1, "name" => "changed"},
        old_row: %{"id" => 1, "name" => "a"},
        lsn: 100
      })

    assert {:ok, [%Message{operation: :update, value: %{"name" => "changed"}}], _offset} =
             RestdisElectric.Log.read(tenant_id, subscribed.handle, subscribed.offset)
  end

  test "resuming below a shape's configured retention window returns must_refetch, not stale data" do
    tenant_id = TestUtils.tenant_id()
    TestUtils.put_stub_rows("widgets", [%{"id" => 1, "name" => "a"}])

    {:ok, subscribed} =
      RestdisElectric.subscribe(tenant_id, @tenant_config, %{
        "table" => "widgets",
        "offset" => "-1",
        "retention" => "2"
      })

    resume_offset = subscribed.offset

    for n <- 1..5 do
      :ok =
        WAL.ingest(%{
          tenant_id: tenant_id,
          schema: "public",
          table: "widgets",
          op: :update,
          pk: 1,
          new_row: %{"id" => 1, "name" => "v#{n}"},
          old_row: %{"id" => 1, "name" => "v#{n - 1}"},
          lsn: 100 + n
        })
    end

    assert {:error, :must_refetch, new_handle} =
             RestdisElectric.subscribe(tenant_id, @tenant_config, %{
               "table" => "widgets",
               "handle" => subscribed.handle,
               "offset" => RestdisElectric.Offset.encode(resume_offset),
               "retention" => "2"
             })

    assert is_binary(new_handle)
  end

  test "a shape with no retention configured never rejects a resume as stale" do
    tenant_id = TestUtils.tenant_id()
    TestUtils.put_stub_rows("widgets", [%{"id" => 1, "name" => "a"}])

    {:ok, subscribed} =
      RestdisElectric.subscribe(tenant_id, @tenant_config, %{
        "table" => "widgets",
        "offset" => "-1"
      })

    resume_offset = subscribed.offset

    for n <- 1..5 do
      :ok =
        WAL.ingest(%{
          tenant_id: tenant_id,
          schema: "public",
          table: "widgets",
          op: :update,
          pk: 1,
          new_row: %{"id" => 1, "name" => "v#{n}"},
          old_row: %{"id" => 1, "name" => "v#{n - 1}"},
          lsn: 100 + n
        })
    end

    assert {:ok, resumed} =
             RestdisElectric.subscribe(tenant_id, @tenant_config, %{
               "table" => "widgets",
               "handle" => subscribed.handle,
               "offset" => RestdisElectric.Offset.encode(resume_offset)
             })

    assert Enum.count(resumed.messages) == 5
  end

  describe "settled reads" do
    test "a read from -1 is not settled while it reaches the tip of the log" do
      tenant_id = TestUtils.tenant_id()

      assert {:ok, result} =
               RestdisElectric.subscribe(tenant_id, @tenant_config, %{
                 "table" => "widgets",
                 "offset" => "-1"
               })

      assert result.settled == false
      assert result.up_to_date == true
    end

    test "a read from -1 stops at the snapshot end once the log has moved past it" do
      tenant_id = TestUtils.tenant_id()

      {:ok, first} =
        RestdisElectric.subscribe(tenant_id, @tenant_config, %{
          "table" => "widgets",
          "offset" => "-1"
        })

      :ok =
        WAL.ingest(%{
          tenant_id: tenant_id,
          schema: "public",
          table: "widgets",
          op: :insert,
          pk: 2,
          new_row: %{"id" => 2, "name" => "b"},
          old_row: nil,
          lsn: 100
        })

      {:ok, second} =
        RestdisElectric.subscribe(tenant_id, @tenant_config, %{
          "table" => "widgets",
          "offset" => "-1",
          "handle" => first.handle
        })

      # The settled response is exactly the snapshot: messages before `0_inf` are already written and never rewritten.
      assert second.settled == true
      assert second.up_to_date == false
      assert second.offset == RestdisElectric.Offset.snapshot_end()
      assert Enum.map(second.messages, & &1.offset) == Enum.map(first.messages, & &1.offset)
    end
  end

  test "a snapshot emits a telemetry event recording the snapshot method used" do
    tenant_id = TestUtils.tenant_id()
    TestUtils.put_stub_rows("widgets", [%{"id" => 1, "name" => "a"}])
    test_pid = self()

    :telemetry.attach(
      "snapshot-method-test",
      [:restdis_electric, :snapshot, :method],
      fn _event, _measurements, metadata, _config -> send(test_pid, {:telemetry, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach("snapshot-method-test") end)

    {:ok, _result} =
      RestdisElectric.subscribe(tenant_id, @tenant_config, %{
        "table" => "widgets",
        "offset" => "-1"
      })

    assert_received {:telemetry, %{method: :postgrest}}
  end

  test "log=changes_only is rejected when the tenant has no direct Postgres pool" do
    tenant_id = TestUtils.tenant_id()

    assert {:error, {:missing_direct_pool, nil}} =
             RestdisElectric.subscribe(tenant_id, @tenant_config, %{
               "table" => "widgets",
               "offset" => "-1",
               "log" => "changes_only"
             })
  end

  test "resuming below the tenant's retention window returns must_refetch" do
    tenant_id = TestUtils.tenant_id()
    TestUtils.put_stub_rows("widgets", [%{"id" => 1, "name" => "a"}])

    tenant_config = Map.put(@tenant_config, :max_log_operations, 1)

    {:ok, first} =
      RestdisElectric.subscribe(tenant_id, tenant_config, %{
        "table" => "widgets",
        "offset" => "-1"
      })

    :ok =
      WAL.ingest(%{
        tenant_id: tenant_id,
        schema: "public",
        table: "widgets",
        op: :insert,
        pk: 1,
        new_row: %{"id" => 1, "name" => "a"},
        old_row: nil,
        lsn: 100
      })

    :ok =
      WAL.ingest(%{
        tenant_id: tenant_id,
        schema: "public",
        table: "widgets",
        op: :insert,
        pk: 2,
        new_row: %{"id" => 2, "name" => "b"},
        old_row: nil,
        lsn: 101
      })

    assert {:error, :must_refetch, _new_handle} =
             RestdisElectric.subscribe(tenant_id, tenant_config, %{
               "table" => "widgets",
               "handle" => first.handle,
               "offset" => RestdisElectric.Offset.encode(first.offset)
             })
  end

  describe "the secret query parameter" do
    test "a request without the configured secret is rejected" do
      tenant_id = TestUtils.tenant_id()
      tenant_config = Map.put(@tenant_config, :shape_secret, "sekrit")

      assert {:error, {:invalid_secret, nil}} =
               RestdisElectric.subscribe(tenant_id, tenant_config, %{
                 "table" => "widgets",
                 "offset" => "-1"
               })
    end

    test "a request with the wrong secret is rejected" do
      tenant_id = TestUtils.tenant_id()
      tenant_config = Map.put(@tenant_config, :shape_secret, "sekrit")

      assert {:error, {:invalid_secret, nil}} =
               RestdisElectric.subscribe(tenant_id, tenant_config, %{
                 "table" => "widgets",
                 "offset" => "-1",
                 "secret" => "wrong"
               })
    end

    test "a request with the matching secret succeeds" do
      tenant_id = TestUtils.tenant_id()
      TestUtils.put_stub_rows("widgets", [])
      tenant_config = Map.put(@tenant_config, :shape_secret, "sekrit")

      assert {:ok, _result} =
               RestdisElectric.subscribe(tenant_id, tenant_config, %{
                 "table" => "widgets",
                 "offset" => "-1",
                 "secret" => "sekrit"
               })
    end

    test "a secret is ignored when the tenant has none configured" do
      tenant_id = TestUtils.tenant_id()
      TestUtils.put_stub_rows("widgets", [])

      assert {:ok, _result} =
               RestdisElectric.subscribe(tenant_id, @tenant_config, %{
                 "table" => "widgets",
                 "offset" => "-1",
                 "secret" => "anything"
               })
    end
  end

  describe "gatekeeper mode" do
    @gatekeeper_config Map.merge(@tenant_config, %{
                         auth_mode: "gatekeeper",
                         shapes: %{
                           "widget-feed" => %{table: "widgets"}
                         }
                       })

    test "the client can subscribe by shape name alone" do
      tenant_id = TestUtils.tenant_id()
      TestUtils.put_stub_rows("widgets", [%{"id" => 1, "name" => "a"}])

      assert {:ok, result} =
               RestdisElectric.subscribe(tenant_id, @gatekeeper_config, %{
                 "shape" => "widget-feed",
                 "offset" => "-1"
               })

      assert result.table == "widgets"
    end

    test "the client sending 'table' is rejected" do
      tenant_id = TestUtils.tenant_id()

      assert {:error, {:forbidden_param, "table"}} =
               RestdisElectric.subscribe(tenant_id, @gatekeeper_config, %{
                 "shape" => "widget-feed",
                 "table" => "widgets",
                 "offset" => "-1"
               })
    end

    test "the client sending 'where' or 'columns' is rejected" do
      tenant_id = TestUtils.tenant_id()

      assert {:error, {:forbidden_param, "where"}} =
               RestdisElectric.subscribe(tenant_id, @gatekeeper_config, %{
                 "shape" => "widget-feed",
                 "where" => "id = 1",
                 "offset" => "-1"
               })

      assert {:error, {:forbidden_param, "columns"}} =
               RestdisElectric.subscribe(tenant_id, @gatekeeper_config, %{
                 "shape" => "widget-feed",
                 "columns" => "id",
                 "offset" => "-1"
               })
    end

    test "a missing shape name is rejected" do
      tenant_id = TestUtils.tenant_id()

      assert {:error, {:missing_shape_name, nil}} =
               RestdisElectric.subscribe(tenant_id, @gatekeeper_config, %{"offset" => "-1"})
    end

    test "an unknown shape name is rejected" do
      tenant_id = TestUtils.tenant_id()

      assert {:error, {:unknown_shape, "nope"}} =
               RestdisElectric.subscribe(tenant_id, @gatekeeper_config, %{
                 "shape" => "nope",
                 "offset" => "-1"
               })
    end
  end

  describe "log=changes_only" do
    @direct_pg_url "postgres://postgres:postgres@#{System.get_env("RESTDIS_POSTGRES_HOSTNAME", "localhost")}:5432/restdis_test"

    setup do
      {:ok, conn} =
        Postgrex.start_link(DirectPostgres.connect_opts(@direct_pg_url))

      Postgrex.query!(conn, "DROP TABLE IF EXISTS changes_only_widgets", [])

      Postgrex.query!(
        conn,
        "CREATE TABLE changes_only_widgets (id integer PRIMARY KEY, name text)",
        []
      )

      Postgrex.query!(
        conn,
        "INSERT INTO changes_only_widgets (id, name) VALUES (1, 'a'), (2, 'b')",
        []
      )

      on_exit(fn ->
        {:ok, conn} =
          Postgrex.start_link(DirectPostgres.connect_opts(@direct_pg_url))

        Postgrex.query!(conn, "DROP TABLE IF EXISTS changes_only_widgets", [])
      end)

      TestUtils.put_table("public.changes_only_widgets", %{
        columns: ["id", "name"],
        primary_key: ["id"],
        replica_identity: :full
      })

      :ok
    end

    test "returns a snapshot-end control message carrying a usable descriptor, and no row inserts" do
      tenant_id = TestUtils.tenant_id()

      tenant_config =
        Map.put(@tenant_config, :direct_pg_url, @direct_pg_url)

      assert {:ok, result} =
               RestdisElectric.subscribe(tenant_id, tenant_config, %{
                 "table" => "changes_only_widgets",
                 "offset" => "-1",
                 "log" => "changes_only"
               })

      assert [message] = result.messages
      assert Message.control?(message)
      assert message.control == :snapshot_end
      assert %{xmin: _, xmax: _, xip_list: _} = message.snapshot
      assert result.up_to_date
    end

    test "log=full for the same shape still returns the full snapshot as row inserts" do
      tenant_id = TestUtils.tenant_id()

      tenant_config =
        Map.put(@tenant_config, :direct_pg_url, @direct_pg_url)

      TestUtils.put_stub_rows("changes_only_widgets", [
        %{"id" => 1, "name" => "a"},
        %{"id" => 2, "name" => "b"}
      ])

      assert {:ok, result} =
               RestdisElectric.subscribe(tenant_id, tenant_config, %{
                 "table" => "changes_only_widgets",
                 "offset" => "-1"
               })

      assert Enum.count(result.messages) == 2
      assert Enum.all?(result.messages, &(&1.operation == :insert))
    end
  end
end
