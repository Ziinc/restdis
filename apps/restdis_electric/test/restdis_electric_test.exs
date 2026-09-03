defmodule RestdisElectricTest do
  use ExUnit.Case, async: false

  alias RestdisElectric.Handle
  alias RestdisElectric.Message
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

    assert length(result.messages) == 2
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

      # The settled response is exactly the snapshot, and it can never change:
      # the messages before `0_inf` are already written and never rewritten.
      assert second.settled == true
      assert second.up_to_date == false
      assert second.offset == RestdisElectric.Offset.snapshot_end()
      assert Enum.map(second.messages, & &1.offset) == Enum.map(first.messages, & &1.offset)
    end
  end
end
