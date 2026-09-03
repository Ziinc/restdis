defmodule RestdisElectric.ShapeRegistryTest do
  use ExUnit.Case, async: true

  alias RestdisElectric.ShapeRegistry
  alias RestdisElectric.TestUtils

  test "handles_for/3 returns handles registered for the exact tenant/schema/table" do
    tenant_id = TestUtils.tenant_id()
    :ok = ShapeRegistry.register(tenant_id, "public", "widgets", "h1")
    :ok = ShapeRegistry.register(tenant_id, "public", "widgets", "h2")
    :ok = ShapeRegistry.register(tenant_id, "public", "gadgets", "h3")

    assert Enum.sort(ShapeRegistry.handles_for(tenant_id, "public", "widgets")) == ["h1", "h2"]
    assert ShapeRegistry.handles_for(tenant_id, "public", "gadgets") == ["h3"]
    assert ShapeRegistry.handles_for("other-tenant", "public", "widgets") == []
  end

  test "tables/0 returns the distinct (tenant_id, schema, table) tuples with at least one shape" do
    tenant_id = TestUtils.tenant_id()
    :ok = ShapeRegistry.register(tenant_id, "public", "widgets", "h1")
    :ok = ShapeRegistry.register(tenant_id, "public", "widgets", "h2")
    :ok = ShapeRegistry.register(tenant_id, "public", "gadgets", "h3")

    tables = ShapeRegistry.tables()

    assert {tenant_id, "public", "widgets"} in tables
    assert {tenant_id, "public", "gadgets"} in tables
  end

  test "unregister/2 removes only the given handle" do
    tenant_id = TestUtils.tenant_id()
    :ok = ShapeRegistry.register(tenant_id, "public", "widgets", "h1")
    :ok = ShapeRegistry.register(tenant_id, "public", "widgets", "h2")

    :ok = ShapeRegistry.unregister(tenant_id, "h1")

    assert ShapeRegistry.handles_for(tenant_id, "public", "widgets") == ["h2"]
  end
end
