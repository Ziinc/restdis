defmodule RestdisServer.Commands.GetMgetPgrstKeyTest do
  use ExUnit.Case, async: false

  import RestdisServer.TestUtils

  alias Restdis.Cache.Key
  alias RestdisServer.Commands.Get
  alias RestdisServer.Commands.Mget

  setup do
    tenant_id = "tenant_get_mget_pgrst_#{System.unique_integer([:positive])}"
    on_exit(fn -> Restdis.Cache.flush_tenant(tenant_id) end)
    {:ok, tenant_id: tenant_id}
  end

  test "GET of a pgrst:* key JSON-encodes the cached value", %{tenant_id: tenant_id} do
    key = Key.build(:table, "products", %{"id" => "eq.1"})
    Restdis.Cache.put(tenant_id, key, [%{"id" => 1}], ttl_ms: 60_000)

    {reply, _state} = Get.run(state(tenant_id), [Key.encode(key)])

    assert IO.iodata_to_binary(reply) =~ Jason.encode!([%{"id" => 1}])
  end

  test "MGET of a pgrst:* key JSON-encodes the cached value", %{tenant_id: tenant_id} do
    key = Key.build(:table, "products", %{"id" => "eq.2"})
    Restdis.Cache.put(tenant_id, key, [%{"id" => 2}], ttl_ms: 60_000)

    {reply, _state} = Mget.run(state(tenant_id), [Key.encode(key)])

    assert IO.iodata_to_binary(reply) =~ Jason.encode!([%{"id" => 2}])
  end
end
