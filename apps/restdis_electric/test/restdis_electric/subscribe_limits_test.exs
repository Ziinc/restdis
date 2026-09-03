defmodule RestdisElectric.SubscribeLimitsTest do
  use ExUnit.Case, async: false

  alias RestdisElectric.Limits
  alias RestdisElectric.Log
  alias RestdisElectric.Offset
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

  test "subscribing to a new shape at the tenant's max_shapes evicts the idle LRU shape instead of rejecting it" do
    tenant_id = TestUtils.tenant_id()
    tenant_config = Map.put(@tenant_config, :max_shapes, 1)
    TestUtils.put_stub_rows("widgets", [%{"id" => 1, "name" => "a"}])
    TestUtils.put_stub_rows("gadgets", [%{"id" => 1}])

    assert {:ok, first} =
             RestdisElectric.subscribe(tenant_id, tenant_config, %{
               "table" => "widgets",
               "offset" => "-1"
             })

    assert {:ok, _second} =
             RestdisElectric.subscribe(tenant_id, tenant_config, %{
               "table" => "gadgets",
               "offset" => "-1"
             })

    # The evicted shape's log is gone, so resuming it must-refetches with a fresh handle.
    assert {:error, :must_refetch, new_handle} =
             RestdisElectric.subscribe(tenant_id, tenant_config, %{
               "table" => "widgets",
               "offset" => Offset.encode({0, 0}),
               "handle" => first.handle
             })

    assert is_binary(new_handle)
  end

  test "subscribing to a new shape returns limit_exceeded when every existing shape is busy" do
    tenant_id = TestUtils.tenant_id()
    tenant_config = Map.put(@tenant_config, :max_shapes, 1)
    TestUtils.put_stub_rows("widgets", [%{"id" => 1, "name" => "a"}])

    assert {:ok, first} =
             RestdisElectric.subscribe(tenant_id, tenant_config, %{
               "table" => "widgets",
               "offset" => "-1"
             })

    parent = self()

    spawn(fn ->
      result = RestdisElectric.await(tenant_id, first.handle, first.offset, 5_000)
      send(parent, {:awaited, result})
    end)

    Process.sleep(50)

    assert {:error, {:limit_exceeded, :shapes, 1}} =
             RestdisElectric.subscribe(tenant_id, tenant_config, %{
               "table" => "gadgets",
               "offset" => "-1"
             })

    Log.append(tenant_id, first.handle, [
      RestdisElectric.Message.change({0, 1}, :insert, "1", %{"id" => 1})
    ])

    assert_receive {:awaited, _result}, 1_000
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
