defmodule RestdisElectric.SchemaWatcherTest do
  use ExUnit.Case, async: false

  alias RestdisElectric.Log
  alias RestdisElectric.SchemaWatcher
  alias RestdisElectric.ShapeRegistry
  alias RestdisElectric.TestUtils

  describe "changed?/2" do
    test "returns false for identical schema snapshots" do
      info = %{columns: ["id", "name"], primary_key: ["id"], replica_identity: :full, types: %{}}
      refute SchemaWatcher.changed?(info, info)
    end

    test "returns true when a column is added" do
      old = %{columns: ["id"], primary_key: ["id"], replica_identity: :full, types: %{}}
      new = %{columns: ["id", "name"], primary_key: ["id"], replica_identity: :full, types: %{}}
      assert SchemaWatcher.changed?(old, new)
    end

    test "returns true when a column's type changes" do
      old = %{
        columns: ["id"],
        primary_key: ["id"],
        replica_identity: :full,
        types: %{"id" => "int4"}
      }

      new = %{
        columns: ["id"],
        primary_key: ["id"],
        replica_identity: :full,
        types: %{"id" => "text"}
      }

      assert SchemaWatcher.changed?(old, new)
    end
  end

  describe "check/0" do
    setup do
      tenant_id = TestUtils.tenant_id()
      tables = Application.get_env(:restdis_electric, :tables, %{})

      Application.put_env(
        :restdis_electric,
        :tables,
        Map.put(tables, "public.drift_watch", %{
          columns: ["id"],
          primary_key: ["id"],
          replica_identity: :full
        })
      )

      handle = "drift-watch-handle"
      :ok = ShapeRegistry.register(tenant_id, "public", "drift_watch", handle)
      {:ok, _pid} = Log.ensure_started(tenant_id, handle)

      on_exit(fn ->
        Application.put_env(:restdis_electric, :tables, tables)
      end)

      %{tenant_id: tenant_id, handle: handle}
    end

    test "leaves an unchanged table's shapes registered", %{tenant_id: tenant_id, handle: handle} do
      SchemaWatcher.check()
      SchemaWatcher.check()

      assert {:ok, _} = ShapeRegistry.fetch(tenant_id, handle)
    end

    test "invalidates every shape on a table whose schema changed", %{
      tenant_id: tenant_id,
      handle: handle
    } do
      # Establishes the baseline snapshot for this table.
      SchemaWatcher.check()

      tables = Application.get_env(:restdis_electric, :tables, %{})

      Application.put_env(
        :restdis_electric,
        :tables,
        Map.put(tables, "public.drift_watch", %{
          columns: ["id", "extra"],
          primary_key: ["id"],
          replica_identity: :full
        })
      )

      SchemaWatcher.check()

      assert ShapeRegistry.fetch(tenant_id, handle) == :error
      assert Log.read(tenant_id, handle, RestdisElectric.Offset.beginning()) == :error
    end
  end
end
