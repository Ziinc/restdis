defmodule RestdisElectric.LimitsTest do
  use ExUnit.Case, async: false

  alias RestdisElectric.Limits
  alias RestdisElectric.ShapeRegistry
  alias RestdisElectric.TestUtils

  test "check_shapes/1 allows any count when no limit is configured" do
    tenant_id = TestUtils.tenant_id()
    assert Limits.check_shapes(tenant_id) == :ok
  end

  test "check_shapes/1 rejects once the tenant's registered shape count reaches its limit" do
    tenant_id = TestUtils.tenant_id()
    Limits.put_config(tenant_id, %{max_shapes: 1})

    assert Limits.check_shapes(tenant_id) == :ok
    :ok = ShapeRegistry.register(tenant_id, "public", "widgets", "h1")
    assert Limits.check_shapes(tenant_id) == {:error, {:limit_exceeded, :shapes, 1}}
  end

  test "check_log_bytes/3 rejects once current plus additional bytes exceed the limit" do
    tenant_id = TestUtils.tenant_id()
    Limits.put_config(tenant_id, %{max_log_bytes: 100})

    assert Limits.check_log_bytes(tenant_id, 50, 40) == :ok

    assert Limits.check_log_bytes(tenant_id, 50, 60) ==
             {:error, {:limit_exceeded, :log_bytes, 100}}
  end

  test "effective_retention/2 uses the shape's own retention when it was registered with one" do
    tenant_id = TestUtils.tenant_id()
    Limits.put_config(tenant_id, %{max_log_operations: 100})

    definition = %RestdisElectric.Definition{
      tenant_id: tenant_id,
      schema: "public",
      table: "widgets",
      retention: 10
    }

    ShapeRegistry.register(tenant_id, definition, "h-retention")

    assert Limits.effective_retention(tenant_id, "h-retention") == 10
  end

  test "effective_retention/2 falls back to the tenant default when the shape has none" do
    tenant_id = TestUtils.tenant_id()
    Limits.put_config(tenant_id, %{max_log_operations: 100})
    :ok = ShapeRegistry.register(tenant_id, "public", "widgets", "h-default")

    assert Limits.effective_retention(tenant_id, "h-default") == 100
  end

  test "effective_retention/2 is nil when neither the shape nor the tenant configures one" do
    tenant_id = TestUtils.tenant_id()
    :ok = ShapeRegistry.register(tenant_id, "public", "widgets", "h-unlimited")

    assert Limits.effective_retention(tenant_id, "h-unlimited") == nil
  end

  test "enter_wait/1 and exit_wait/1 enforce the waiting-clients limit" do
    tenant_id = TestUtils.tenant_id()
    Limits.put_config(tenant_id, %{max_waiting_clients: 1})

    assert Limits.enter_wait(tenant_id) == :ok
    assert Limits.enter_wait(tenant_id) == {:error, {:limit_exceeded, :waiting_clients, 1}}

    :ok = Limits.exit_wait(tenant_id)
    assert Limits.enter_wait(tenant_id) == :ok
  end
end
