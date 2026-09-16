defmodule RestdisReplicator.SubscriptionTest do
  use ExUnit.Case, async: false

  alias RestdisReplicator.Origin.Stub
  alias RestdisReplicator.Subscription
  alias RestdisReplicator.TestUtils

  setup do
    dataset = TestUtils.dataset()
    on_exit(fn -> TestUtils.cleanup(dataset) end)
    {:ok, dataset: dataset}
  end

  test "subscription stores every row as a KV pair", %{dataset: dataset} do
    TestUtils.seed(dataset, TestUtils.rows(dataset, 5))

    assert {:ok, ^dataset} = RestdisReplicator.subscribe(dataset)

    assert {:ok, %{"name" => "row-3"}} =
             RestdisReplicator.get(dataset.tenant_id, dataset.table, 3)

    assert :miss = RestdisReplicator.get(dataset.tenant_id, dataset.table, 99)
  end

  test "initial load paginates the origin", %{dataset: dataset} do
    TestUtils.seed(dataset, TestUtils.rows(dataset, 5))

    {:ok, _} = RestdisReplicator.subscribe(dataset)

    # page_size is 2 in the test environment: 2 + 2 + 1
    assert Stub.page_calls(dataset) == 3
  end

  # The 10,000-row load runs well past ExUnit's 60s default when the suite is
  # instrumented for coverage on a shared CI runner.
  @tag :slow
  @tag timeout: 180_000
  test "a replicated table with 10,000 rows loads fully", %{dataset: dataset} do
    Application.put_env(:restdis_replicator, :page_size, 1_000)
    on_exit(fn -> Application.put_env(:restdis_replicator, :page_size, 2) end)

    TestUtils.seed(dataset, TestUtils.rows(dataset, 10_000))

    {:ok, _} = RestdisReplicator.subscribe(dataset)

    assert Enum.count(Subscription.primary_keys(dataset)) == 10_000

    assert {:ok, %{"name" => "row-10000"}} =
             RestdisReplicator.get(dataset.tenant_id, dataset.table, 10_000)
  end

  test "refresh_row/2 updates the KV entry in place", %{dataset: dataset} do
    TestUtils.seed(dataset, TestUtils.rows(dataset, 2))
    {:ok, _} = RestdisReplicator.subscribe(dataset)

    TestUtils.seed(dataset, [%{"id" => 1, "name" => "updated"}, %{"id" => 2, "name" => "row-2"}])
    :ok = RestdisReplicator.refresh_row(dataset, 1)
    Subscription.await_loaded(dataset)

    assert {:ok, %{"name" => "updated"}} =
             RestdisReplicator.get(dataset.tenant_id, dataset.table, 1)

    assert {:ok, %{"name" => "row-2"}} =
             RestdisReplicator.get(dataset.tenant_id, dataset.table, 2)
  end

  test "refresh_row/2 removes an entry the origin no longer returns", %{dataset: dataset} do
    TestUtils.seed(dataset, TestUtils.rows(dataset, 2))
    {:ok, _} = RestdisReplicator.subscribe(dataset)

    TestUtils.seed(dataset, [%{"id" => 2, "name" => "row-2"}])
    :ok = RestdisReplicator.refresh_row(dataset, 1)
    Subscription.await_loaded(dataset)

    assert :miss = RestdisReplicator.get(dataset.tenant_id, dataset.table, 1)
  end

  test "delete_row/2 removes the KV entry", %{dataset: dataset} do
    TestUtils.seed(dataset, TestUtils.rows(dataset, 2))
    {:ok, _} = RestdisReplicator.subscribe(dataset)

    :ok = RestdisReplicator.delete_row(dataset, 2)
    Subscription.await_loaded(dataset)

    assert :miss = RestdisReplicator.get(dataset.tenant_id, dataset.table, 2)
    assert Subscription.primary_keys(dataset) == ["1"]
  end

  test "reconcile/1 removes stale entries and loads new ones", %{dataset: dataset} do
    TestUtils.seed(dataset, TestUtils.rows(dataset, 3))
    {:ok, _} = RestdisReplicator.subscribe(dataset)

    TestUtils.seed(dataset, [%{"id" => 1, "name" => "row-1"}, %{"id" => 4, "name" => "row-4"}])

    assert {:ok, 2} = RestdisReplicator.reconcile(dataset)

    assert :miss = RestdisReplicator.get(dataset.tenant_id, dataset.table, 2)
    assert :miss = RestdisReplicator.get(dataset.tenant_id, dataset.table, 3)

    assert {:ok, %{"name" => "row-4"}} =
             RestdisReplicator.get(dataset.tenant_id, dataset.table, 4)

    assert Enum.sort(Subscription.primary_keys(dataset)) == ["1", "4"]
  end

  test "rows without a primary key are skipped", %{dataset: dataset} do
    TestUtils.seed(dataset, [%{"name" => "no-pk"}, %{"id" => 1, "name" => "row-1"}])

    {:ok, _} = RestdisReplicator.subscribe(dataset)

    assert Subscription.primary_keys(dataset) == ["1"]
  end
end
