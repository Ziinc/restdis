defmodule RestdisBuster.TelemetryTest do
  use ExUnit.Case, async: false

  alias Restdis.Cache.Key
  alias Restdis.Cache.ReverseIndex
  alias Restdis.Cache.TenantSupervisor
  alias RestdisBuster.TestUtils
  alias RestdisBuster.WAL.Event
  alias RestdisBuster.Worker

  setup do
    TenantSupervisor.ensure_started("tel-tenant")
    on_exit(fn -> Restdis.Cache.flush_tenant("tel-tenant") end)
    :ok
  end

  defp seed_config(schema, table, config) do
    TestUtils.seed_table_config(schema, table, config)
  end

  defp clear_config do
    TestUtils.clear_table_config()
  end

  defp attach(handler_id, events) do
    test_pid = self()

    :telemetry.attach_many(
      handler_id,
      events,
      fn event_name, measurements, metadata, _cfg ->
        send(test_pid, {:telemetry, event_name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  test "Worker emits [:event, :processed] with op/schema/table metadata on DML" do
    config = %{
      tenant_id: "tel-tenant",
      schema: "public",
      table_name: "tel_products",
      pk_column: "id",
      mode: "ttl"
    }

    seed_config("public", "tel_products", config)
    on_exit(&clear_config/0)

    attach("test-processed", [[:restdis_buster, :event, :processed]])

    key = Key.build(:table, "tel_products", %{})
    Restdis.Cache.put("tel-tenant", key, %{"id" => 5}, primary_keys: [5])

    event = TestUtils.update_event("tel_products", "public", %{"id" => "5"}, %{"id" => "5"})
    Worker.run(event)

    assert_receive {:telemetry, [:restdis_buster, :event, :processed], measurements,
                    metadata},
                   500

    assert measurements.count == 1
    assert is_integer(measurements.duration_us)
    assert metadata.op == :update
    assert metadata.schema == "public"
    assert metadata.table == "tel_products"
  end

  test "Worker emits [:invalidation, :latency] after invalidate_by_row" do
    config = %{
      tenant_id: "tel-tenant",
      schema: "public",
      table_name: "tel_products",
      pk_column: "id",
      mode: "ttl"
    }

    seed_config("public", "tel_products", config)
    on_exit(&clear_config/0)

    attach("test-inv-latency", [[:restdis_buster, :invalidation, :latency]])

    key = Key.build(:table, "tel_products", %{})
    Restdis.Cache.put("tel-tenant", key, %{"id" => 5}, primary_keys: [5])

    event = TestUtils.update_event("tel_products", "public", %{"id" => "5"}, %{"id" => "5"})
    Worker.run(event)

    assert_receive {:telemetry, [:restdis_buster, :invalidation, :latency], measurements,
                    metadata},
                   500

    assert is_integer(measurements.duration_us)
    assert metadata.tenant_id == "tel-tenant"
    assert metadata.table == "tel_products"
    assert metadata.op == :update
  end

  test "Worker emits [:invalidation, :latency] after flush_table on truncate" do
    config = %{
      tenant_id: "tel-tenant",
      schema: "public",
      table_name: "tel_products",
      pk_column: "id",
      mode: "ttl"
    }

    seed_config("public", "tel_products", config)
    on_exit(&clear_config/0)

    attach("test-inv-latency-trunc", [[:restdis_buster, :invalidation, :latency]])

    event = TestUtils.truncate_event("tel_products")
    Worker.run(event)

    assert_receive {:telemetry, [:restdis_buster, :invalidation, :latency], measurements,
                    metadata},
                   500

    assert is_integer(measurements.duration_us)
    assert metadata.tenant_id == "tel-tenant"
    assert metadata.table == "tel_products"
    assert metadata.op == :truncate
  end

  test "ReverseIndex emits :hit when keys exist" do
    attach("test-rev-hit", [[:restdis_buster, :reverse_index, :hit]])

    key = Key.build(:table, "tel_hits", %{})
    Restdis.Cache.put("tel-tenant", key, %{"id" => 1}, primary_keys: [1])

    ReverseIndex.purge_row("tel-tenant", "tel_hits", 1)

    assert_receive {:telemetry, [:restdis_buster, :reverse_index, :hit], measurements,
                    metadata},
                   500

    assert measurements.keys >= 1
    assert metadata.tenant_id == "tel-tenant"
    assert metadata.table == "tel_hits"
  end

  test "ReverseIndex emits :miss when no keys exist" do
    attach("test-rev-miss", [[:restdis_buster, :reverse_index, :miss]])

    ReverseIndex.purge_row("tel-tenant", "tel_unknown", 999)

    assert_receive {:telemetry, [:restdis_buster, :reverse_index, :miss], %{count: 1},
                    metadata},
                   500

    assert metadata.tenant_id == "tel-tenant"
    assert metadata.table == "tel_unknown"
  end

  test "received_at = nil yields duration_us = 0 (no crash)" do
    config = %{
      tenant_id: "tel-tenant",
      schema: "public",
      table_name: "tel_products",
      pk_column: "id",
      mode: "ttl"
    }

    seed_config("public", "tel_products", config)
    on_exit(&clear_config/0)

    attach("test-nil-received", [[:restdis_buster, :event, :processed]])

    event = %Event{
      op: :insert,
      schema: "public",
      table: "tel_products",
      new_row: %{"id" => "1"},
      received_at: nil
    }

    Worker.run(event)

    assert_receive {:telemetry, [:restdis_buster, :event, :processed], %{duration_us: 0}, _},
                   500
  end
end
