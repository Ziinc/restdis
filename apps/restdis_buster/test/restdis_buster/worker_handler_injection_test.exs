defmodule RestdisBuster.WorkerHandlerInjectionTest do
  use ExUnit.Case, async: false

  alias RestdisBuster.TestUtils
  alias RestdisBuster.Worker

  @moduledoc """
  Proves `RestdisBuster.Worker` dispatches invalidation through an injected
  `Restdis.Wal.Handler` implementation rather than calling `Restdis.Cache`
  directly (LIB_PRD Phase 4, step 7-8).
  """

  defmodule StubHandler do
    @behaviour Restdis.Wal.Handler

    @impl Restdis.Wal.Handler
    def invalidate_by_row(tenant_id, table, pk) do
      send(:handler_injection_test, {:invalidate_by_row, tenant_id, table, pk})
      :ok
    end

    @impl Restdis.Wal.Handler
    def flush_table(tenant_id, table) do
      send(:handler_injection_test, {:flush_table, tenant_id, table})
      :ok
    end
  end

  setup do
    Process.register(self(), :handler_injection_test)
    Application.put_env(:restdis_buster, :wal_handler, StubHandler)

    on_exit(fn ->
      Application.delete_env(:restdis_buster, :wal_handler)

      try do
        Process.unregister(:handler_injection_test)
      rescue
        _ -> :ok
      end
    end)

    :ok
  end

  defp seed_config(schema, table, config), do: TestUtils.seed_table_config(schema, table, config)
  defp clear_config, do: TestUtils.clear_table_config()

  test "a row-level DML event dispatches to the configured handler's invalidate_by_row/3" do
    config = %{
      tenant_id: "tenant_stub",
      schema: "public",
      table_name: "products",
      pk_column: "id",
      mode: "ttl"
    }

    seed_config("public", "products", config)
    on_exit(&clear_config/0)

    event = TestUtils.update_event("products", "public", %{"id" => "42"}, %{"id" => "42"})
    Worker.run(event)

    assert_receive {:invalidate_by_row, "tenant_stub", "products", 42}, 200
  end

  test "a truncate event dispatches to the configured handler's flush_table/2" do
    config = %{
      tenant_id: "tenant_stub",
      schema: "public",
      table_name: "products",
      pk_column: "id",
      mode: "ttl"
    }

    seed_config("public", "products", config)
    on_exit(&clear_config/0)

    event = TestUtils.truncate_event("products")
    Worker.run(event)

    assert_receive {:flush_table, "tenant_stub", "products"}, 200
  end
end
