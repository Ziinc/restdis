defmodule RestdisServer.RewarmTest do
  use ExUnit.Case, async: false

  alias Restdis.Cache.Key
  alias RestdisServer.Rewarm

  setup do
    tenant_id = "tenant_rewarm_#{System.unique_integer([:positive])}"
    on_exit(fn -> Rewarm.stop_tenant(tenant_id) end)
    {:ok, tenant_id: tenant_id}
  end

  test "touch/3 is a no-op when the key has no rewarm policy", %{tenant_id: tenant_id} do
    key = Key.build(:table, "products", %{})
    assert :ok = Rewarm.touch(tenant_id, Key.encode(key), key)
  end

  test "policy_changed/4 with rewarm_s nil and no active scheduler is a no-op", %{
    tenant_id: tenant_id
  } do
    key = Key.build(:table, "products", %{})

    assert :ok =
             Rewarm.policy_changed(tenant_id, Key.encode(key), key, %{
               rewarm_s: nil,
               persist: false
             })
  end

  test "stop_tenant/1 is a no-op when there is no active scheduler", %{tenant_id: tenant_id} do
    assert :ok = Rewarm.stop_tenant(tenant_id)
  end

  test "set_rewarm/4 then policy_changed/4 with rewarm_s nil clears an active scheduler", %{
    tenant_id: tenant_id
  } do
    key = Key.build(:table, "products", %{})
    wire_key = Key.encode(key)

    :ok = Rewarm.set_rewarm(tenant_id, wire_key, key, 30)

    assert :ok =
             Rewarm.policy_changed(tenant_id, wire_key, key, %{rewarm_s: nil, persist: false})
  end
end
