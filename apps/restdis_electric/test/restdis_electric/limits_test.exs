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

  test "enter_wait/1 and exit_wait/1 enforce the waiting-clients limit" do
    tenant_id = TestUtils.tenant_id()
    Limits.put_config(tenant_id, %{max_waiting_clients: 1})

    assert Limits.enter_wait(tenant_id) == :ok
    assert Limits.enter_wait(tenant_id) == {:error, {:limit_exceeded, :waiting_clients, 1}}

    :ok = Limits.exit_wait(tenant_id)
    assert Limits.enter_wait(tenant_id) == :ok
  end
end
