defmodule RestdisElectric.WALFilterTest do
  @moduledoc """
  Rows that enter and leave a shape.

  Without this the client's copy is wrong, not merely stale: it keeps rows the
  filter no longer accepts and never learns about rows that started matching.
  """

  use ExUnit.Case, async: false

  alias RestdisElectric.Definition
  alias RestdisElectric.Log
  alias RestdisElectric.Offset
  alias RestdisElectric.ShapeRegistry
  alias RestdisElectric.TestUtils
  alias RestdisElectric.WAL

  setup do
    TestUtils.put_table("public.orders", %{
      columns: ["id", "org_id", "status", "note"],
      primary_key: ["id"],
      replica_identity: :full
    })

    %{tenant_id: TestUtils.tenant_id()}
  end

  defp register(tenant_id, handle, params) do
    {:ok, definition} = Definition.new(tenant_id, Map.put(params, "table", "orders"))
    :ok = ShapeRegistry.register(tenant_id, definition, handle)
    handle
  end

  defp change(tenant_id, op, lsn, new_row, old_row) do
    :ok =
      WAL.ingest(%{
        tenant_id: tenant_id,
        schema: "public",
        table: "orders",
        op: op,
        pk: (new_row || old_row)["id"],
        new_row: new_row,
        old_row: old_row,
        lsn: lsn
      })
  end

  defp messages(tenant_id, handle) do
    case Log.read(tenant_id, handle, Offset.beginning()) do
      {:ok, messages, _last} -> messages
      :error -> []
    end
  end

  defp row(org_id, status \\ "open"),
    do: %{"id" => 1, "org_id" => org_id, "status" => status, "note" => "n"}

  test "an insert that does not match the filter is not logged", %{tenant_id: tenant_id} do
    register(tenant_id, "h", %{"where" => "org_id = 1"})

    change(tenant_id, :insert, 1, row(2), nil)

    assert messages(tenant_id, "h") == []
  end

  test "an insert that matches the filter is logged", %{tenant_id: tenant_id} do
    register(tenant_id, "h", %{"where" => "org_id = 1"})

    change(tenant_id, :insert, 1, row(1), nil)

    assert [%{operation: :insert, value: %{"org_id" => 1}}] = messages(tenant_id, "h")
  end

  test "an update that moves a row into the shape produces an insert", %{tenant_id: tenant_id} do
    register(tenant_id, "h", %{"where" => "org_id = 1"})

    change(tenant_id, :update, 1, row(1), row(2))

    assert [%{operation: :insert, value: %{"org_id" => 1}}] = messages(tenant_id, "h")
  end

  test "an update that moves a row out of the shape produces a delete", %{tenant_id: tenant_id} do
    register(tenant_id, "h", %{"where" => "org_id = 1"})

    change(tenant_id, :insert, 1, row(1), nil)
    change(tenant_id, :update, 2, row(2), row(1))

    assert [%{operation: :insert}, %{operation: :delete, value: %{"org_id" => 1}}] =
             messages(tenant_id, "h")
  end

  test "an update inside the shape stays an update", %{tenant_id: tenant_id} do
    register(tenant_id, "h", %{"where" => "org_id = 1"})

    change(tenant_id, :update, 1, row(1, "closed"), row(1, "open"))

    assert [%{operation: :update, value: %{"status" => "closed"}}] = messages(tenant_id, "h")
  end

  test "an update outside the shape logs nothing", %{tenant_id: tenant_id} do
    register(tenant_id, "h", %{"where" => "org_id = 1"})

    change(tenant_id, :update, 1, row(2, "closed"), row(2, "open"))

    assert messages(tenant_id, "h") == []
  end

  test "a delete is logged only when the row was in the shape", %{tenant_id: tenant_id} do
    register(tenant_id, "in", %{"where" => "org_id = 1"})
    register(tenant_id, "out", %{"where" => "org_id = 9"})

    change(tenant_id, :delete, 1, nil, row(1))

    assert [%{operation: :delete, key: "1"}] = messages(tenant_id, "in")
    assert messages(tenant_id, "out") == []
  end

  test "the client's data after enter and leave matches a fresh snapshot", %{tenant_id: tenant_id} do
    register(tenant_id, "h", %{"where" => "org_id = 1"})

    change(tenant_id, :insert, 1, row(1), nil)
    change(tenant_id, :update, 2, row(1, "closed"), row(1, "open"))
    change(tenant_id, :update, 3, row(2, "closed"), row(1, "closed"))

    change(
      tenant_id,
      :insert,
      4,
      %{"id" => 2, "org_id" => 1, "status" => "open", "note" => "b"},
      nil
    )

    replayed =
      Enum.reduce(messages(tenant_id, "h"), %{}, fn message, state ->
        case message.operation do
          :delete -> Map.delete(state, message.key)
          :insert -> Map.put(state, message.key, message.value)
          :update -> Map.update!(state, message.key, &Map.merge(&1, message.value))
        end
      end)

    # Row 1 left the shape, row 2 is in it: exactly what a fresh snapshot of `org_id = 1` would return.
    assert Map.keys(replayed) == ["2"]
  end

  describe "replica" do
    test "replica=default omits old_value", %{tenant_id: tenant_id} do
      register(tenant_id, "h", %{})

      change(tenant_id, :update, 1, row(1, "closed"), row(1, "open"))

      assert [%{old_value: nil}] = messages(tenant_id, "h")
    end

    test "replica=full carries the complete old row on an update", %{tenant_id: tenant_id} do
      register(tenant_id, "h", %{"replica" => "full"})

      change(tenant_id, :update, 1, row(1, "closed"), row(1, "open"))

      assert [%{operation: :update, old_value: %{"status" => "open"}}] = messages(tenant_id, "h")
    end

    test "replica=full carries the complete old row on a delete", %{tenant_id: tenant_id} do
      register(tenant_id, "h", %{"replica" => "full"})

      change(tenant_id, :delete, 1, nil, row(1, "open"))

      assert [%{operation: :delete, old_value: %{"status" => "open", "note" => "n"}}] =
               messages(tenant_id, "h")
    end

    test "replica=full leaves an insert alone", %{tenant_id: tenant_id} do
      register(tenant_id, "h", %{"replica" => "full"})

      change(tenant_id, :insert, 1, row(1), nil)

      assert [%{operation: :insert, old_value: nil}] = messages(tenant_id, "h")
    end
  end

  describe "columns" do
    test "a change carries only the columns the shape asked for", %{tenant_id: tenant_id} do
      register(tenant_id, "h", %{"columns" => "id,org_id", "replica" => "full"})

      change(tenant_id, :update, 1, row(1, "closed"), row(1, "open"))

      assert [%{value: value, old_value: old_value}] = messages(tenant_id, "h")
      assert Map.keys(value) == ["id", "org_id"]
      assert Map.keys(old_value) == ["id", "org_id"]
    end
  end

  test "a change reaches only the shapes whose filter accepts it", %{tenant_id: tenant_id} do
    register(tenant_id, "one", %{"where" => "org_id = 1"})
    register(tenant_id, "two", %{"where" => "org_id = 2"})
    register(tenant_id, "all", %{})

    change(tenant_id, :insert, 1, row(2), nil)

    assert messages(tenant_id, "one") == []
    assert [%{operation: :insert}] = messages(tenant_id, "two")
    assert [%{operation: :insert}] = messages(tenant_id, "all")
  end

  test "unregistering stops a shape receiving changes", %{tenant_id: tenant_id} do
    register(tenant_id, "h", %{"where" => "org_id = 1"})
    ShapeRegistry.unregister(tenant_id, "h")

    change(tenant_id, :insert, 1, row(1), nil)

    assert messages(tenant_id, "h") == []
  end
end
