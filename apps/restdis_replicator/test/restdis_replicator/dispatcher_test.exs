defmodule RestdisReplicator.DispatcherTest do
  use ExUnit.Case, async: false

  alias RestdisReplicator.Dispatcher
  alias RestdisReplicator.Subscription
  alias RestdisReplicator.TestUtils

  setup do
    dataset = TestUtils.dataset()
    on_exit(fn -> TestUtils.cleanup(dataset) end)

    config = %{
      tenant_id: dataset.tenant_id,
      schema: dataset.schema,
      table_name: dataset.table,
      mode: "replication",
      pk_column: dataset.pk_column
    }

    {:ok, dataset: dataset, config: config}
  end

  test "an update refreshes the row instead of deleting it", %{dataset: dataset, config: config} do
    TestUtils.seed(dataset, TestUtils.rows(dataset, 2))
    {:ok, _} = RestdisReplicator.subscribe(dataset)

    TestUtils.seed(dataset, [%{"id" => 1, "name" => "fresh"}, %{"id" => 2, "name" => "row-2"}])
    :ok = Dispatcher.dispatch(config, :update, %{"id" => "1", "name" => "fresh"})
    Subscription.await_loaded(dataset)

    assert {:ok, %{"name" => "fresh"}} =
             RestdisReplicator.get(dataset.tenant_id, dataset.table, 1)
  end

  test "an insert on an unsubscribed dataset loads it and stores the row", %{
    dataset: dataset,
    config: config
  } do
    TestUtils.seed(dataset, [%{"id" => 7, "name" => "row-7"}])

    refute RestdisReplicator.subscribed?(dataset)

    :ok = Dispatcher.dispatch(config, :insert, %{"id" => 7})
    Subscription.await_loaded(dataset)

    assert {:ok, %{"name" => "row-7"}} =
             RestdisReplicator.get(dataset.tenant_id, dataset.table, 7)
  end

  test "a delete removes the KV entry", %{dataset: dataset, config: config} do
    TestUtils.seed(dataset, TestUtils.rows(dataset, 2))
    {:ok, _} = RestdisReplicator.subscribe(dataset)

    :ok = Dispatcher.dispatch(config, :delete, %{"id" => 1})
    Subscription.await_loaded(dataset)

    assert :miss = RestdisReplicator.get(dataset.tenant_id, dataset.table, 1)
    assert {:ok, _} = RestdisReplicator.get(dataset.tenant_id, dataset.table, 2)
  end

  test "a row without the primary key column is ignored", %{config: config} do
    assert :ok = Dispatcher.dispatch(config, :update, %{"name" => "no-pk"})
  end
end
