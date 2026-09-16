defmodule RestdisServer.Integration.ReplicationE2ETest do
  use ExUnit.Case, async: false

  import RestdisServer.TestUtils

  alias RestdisReplicator.Dataset
  alias RestdisReplicator.Dispatcher
  alias RestdisReplicator.Origin.Stub
  alias RestdisReplicator.Subscription
  alias RestdisServer.Commands.Get

  setup do
    tenant_id = "tenant_repl_e2e_#{System.unique_integer([:positive])}"

    dataset =
      Dataset.new(%{tenant_id: tenant_id, table_name: "products", pk_column: "id"})

    config = %{
      tenant_id: tenant_id,
      schema: "public",
      table_name: "products",
      mode: "replication",
      pk_column: "id"
    }

    on_exit(fn ->
      RestdisReplicator.unsubscribe(dataset)
      Stub.clear(dataset)
      Restdis.Cache.flush_tenant(tenant_id)
    end)

    {:ok, tenant_id: tenant_id, dataset: dataset, config: config}
  end

  test "GET products:42 returns row data current with the last WAL change", %{
    tenant_id: tenant_id,
    dataset: dataset,
    config: config
  } do
    Stub.seed(dataset, [%{"id" => 42, "name" => "widget"}])
    {:ok, _} = RestdisReplicator.subscribe(dataset)

    {reply, _} = Get.run(state(tenant_id), ["products:42"])
    assert IO.iodata_to_binary(reply) =~ "widget"

    # A write lands in Postgres and the buster dispatches a refresh.
    Stub.seed(dataset, [%{"id" => 42, "name" => "gadget"}])
    :ok = Dispatcher.dispatch(config, :update, %{"id" => "42"})
    Subscription.await_loaded(dataset)

    {reply, _} = Get.run(state(tenant_id), ["products:42"])
    assert IO.iodata_to_binary(reply) =~ "gadget"
  end

  test "a WAL delete removes the row from GET", %{
    tenant_id: tenant_id,
    dataset: dataset,
    config: config
  } do
    Stub.seed(dataset, [%{"id" => 42, "name" => "widget"}])
    {:ok, _} = RestdisReplicator.subscribe(dataset)

    :ok = Dispatcher.dispatch(config, :delete, %{"id" => "42"})
    Subscription.await_loaded(dataset)

    {reply, _} = Get.run(state(tenant_id), ["products:42"])
    assert IO.iodata_to_binary(reply) == "$-1\r\n"
  end
end
