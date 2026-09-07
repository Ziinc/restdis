defmodule RestdisElectric.WALTest do
  use ExUnit.Case, async: false

  alias RestdisElectric.Log
  alias RestdisElectric.Offset
  alias RestdisElectric.ShapeRegistry
  alias RestdisElectric.TestUtils
  alias RestdisElectric.WAL

  test "ingest/1 is a no-op when no shape reads the table" do
    tenant_id = TestUtils.tenant_id()

    assert :ok =
             WAL.ingest(%{
               tenant_id: tenant_id,
               schema: "public",
               table: "untracked",
               op: :insert,
               pk: 1,
               new_row: %{"id" => 1},
               old_row: nil,
               lsn: 1
             })
  end

  test "ingest/1 appends a change to every registered shape reading that table" do
    tenant_id = TestUtils.tenant_id()
    :ok = ShapeRegistry.register(tenant_id, "public", "widgets", "h1")
    :ok = ShapeRegistry.register(tenant_id, "public", "widgets", "h2")

    :ok =
      WAL.ingest(%{
        tenant_id: tenant_id,
        schema: "public",
        table: "widgets",
        op: :insert,
        pk: 1,
        new_row: %{"id" => 1, "name" => "a"},
        old_row: nil,
        lsn: 42
      })

    assert {:ok, [message1], _} = Log.read(tenant_id, "h1", Offset.beginning())
    assert {:ok, [message2], _} = Log.read(tenant_id, "h2", Offset.beginning())
    assert message1.operation == :insert
    assert message1.value == %{"id" => 1, "name" => "a"}
    assert message1.key == "1"
    assert {42, _} = message1.offset
    assert message2.offset == message1.offset
  end

  test "ingest/1 ignores an event with no LSN or no tenant" do
    assert :ok = WAL.ingest(%{tenant_id: nil, lsn: 1})
    assert :ok = WAL.ingest(%{tenant_id: "t", lsn: nil})
  end

  test "ingest/1 falls through to a no-op for a shape it cannot decode" do
    assert :ok = WAL.ingest(%{tenant_id: "t", lsn: 1, op: :truncate})

    assert :ok =
             WAL.ingest(%{tenant_id: 123, schema: "s", table: "t", op: :insert, pk: 1, lsn: 1})
  end

  test "ingest/1 logs a delete when a row leaves a shape" do
    tenant_id = TestUtils.tenant_id()
    :ok = ShapeRegistry.register(tenant_id, "public", "widgets", "h_delete")

    :ok =
      WAL.ingest(%{
        tenant_id: tenant_id,
        schema: "public",
        table: "widgets",
        op: :delete,
        pk: 1,
        new_row: nil,
        old_row: %{"id" => 1, "name" => "a"},
        lsn: 1
      })

    assert {:ok, [message], _} = Log.read(tenant_id, "h_delete", Offset.beginning())
    assert message.operation == :delete
    assert message.value == %{"id" => 1, "name" => "a"}
  end

  test "ingest/1 logs an update and carries the old value for a replica=full shape" do
    tenant_id = TestUtils.tenant_id()

    definition = %RestdisElectric.Definition{
      tenant_id: tenant_id,
      schema: "public",
      table: "widgets",
      replica: :full
    }

    :ok = ShapeRegistry.register(tenant_id, definition, "h_full")

    :ok =
      WAL.ingest(%{
        tenant_id: tenant_id,
        schema: "public",
        table: "widgets",
        op: :update,
        pk: 1,
        new_row: %{"id" => 1, "name" => "b"},
        old_row: %{"id" => 1, "name" => "a"},
        lsn: 1
      })

    assert {:ok, [message], _} = Log.read(tenant_id, "h_full", Offset.beginning())
    assert message.operation == :update
    assert message.value == %{"id" => 1, "name" => "b"}
    assert message.old_value == %{"id" => 1, "name" => "a"}
  end
end
