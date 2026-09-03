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
end
