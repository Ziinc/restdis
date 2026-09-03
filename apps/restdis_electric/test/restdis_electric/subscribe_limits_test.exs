defmodule RestdisElectric.SubscribeLimitsTest do
  use ExUnit.Case, async: false

  alias RestdisElectric.Limits
  alias RestdisElectric.TestUtils

  @tenant_config %{pgrst_base_url: "http://origin", pgrst_api_key: "key"}

  setup do
    TestUtils.put_table("public.widgets", %{
      columns: ["id", "name"],
      primary_key: ["id"],
      replica_identity: :full
    })

    TestUtils.put_table("public.gadgets", %{
      columns: ["id"],
      primary_key: ["id"],
      replica_identity: :full
    })

    :ok
  end

  test "subscribing to a new shape beyond the tenant's max_shapes returns a limit_exceeded error" do
    tenant_id = TestUtils.tenant_id()
    tenant_config = Map.put(@tenant_config, :max_shapes, 1)
    TestUtils.put_stub_rows("widgets", [%{"id" => 1, "name" => "a"}])

    assert {:ok, _first} =
             RestdisElectric.subscribe(tenant_id, tenant_config, %{
               "table" => "widgets",
               "offset" => "-1"
             })

    assert {:error, {:limit_exceeded, :shapes, 1}} =
             RestdisElectric.subscribe(tenant_id, tenant_config, %{
               "table" => "gadgets",
               "offset" => "-1"
             })
  end

  test "subscribing from -1 surfaces a log-bytes limit exceeded during snapshotting" do
    tenant_id = TestUtils.tenant_id()
    tenant_config = Map.put(@tenant_config, :max_log_bytes, 1)
    TestUtils.put_stub_rows("widgets", [%{"id" => 1, "name" => "a"}])

    assert {:error, {:limit_exceeded, :log_bytes, 1}} =
             RestdisElectric.subscribe(tenant_id, tenant_config, %{
               "table" => "widgets",
               "offset" => "-1"
             })
  end

  test "await/4 rejects once the tenant's max_waiting_clients is reached" do
    tenant_id = TestUtils.tenant_id()
    tenant_config = Map.put(@tenant_config, :max_waiting_clients, 0)
    Limits.put_config(tenant_id, tenant_config)

    assert RestdisElectric.await(tenant_id, "some-handle", RestdisElectric.Offset.beginning(), 50) ==
             {:error, {:limit_exceeded, :waiting_clients, 0}}
  end
end
