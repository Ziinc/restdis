defmodule SupaCacherReplicator.SubscriptionTest do
  use ExUnit.Case, async: false

  alias SupaCacherReplicator.Origin.Stub
  alias SupaCacherReplicator.Subscription
  alias SupaCacherReplicator.TestUtils

  setup do
    dataset = TestUtils.dataset()
    on_exit(fn -> TestUtils.cleanup(dataset) end)
    {:ok, dataset: dataset}
  end

  test "subscription stores every row as a KV pair", %{dataset: dataset} do
    TestUtils.seed(dataset, TestUtils.rows(dataset, 5))

    assert {:ok, ^dataset} = SupaCacherReplicator.subscribe(dataset)

    assert {:ok, %{"name" => "row-3"}} =
             SupaCacherReplicator.get(dataset.tenant_id, dataset.table, 3)

    assert :miss = SupaCacherReplicator.get(dataset.tenant_id, dataset.table, 99)
  end

  test "initial load paginates the origin", %{dataset: dataset} do
    TestUtils.seed(dataset, TestUtils.rows(dataset, 5))

    {:ok, _} = SupaCacherReplicator.subscribe(dataset)

    # page_size is 2 in the test environment: 2 + 2 + 1
    assert Stub.page_calls(dataset) == 3
  end

  @tag :slow
  test "a replicated table with 10,000 rows loads fully", %{dataset: dataset} do
    Application.put_env(:supa_cacher_replicator, :page_size, 1_000)
    on_exit(fn -> Application.put_env(:supa_cacher_replicator, :page_size, 2) end)

    TestUtils.seed(dataset, TestUtils.rows(dataset, 10_000))

    {:ok, _} = SupaCacherReplicator.subscribe(dataset)

    assert length(Subscription.primary_keys(dataset)) == 10_000

    assert {:ok, %{"name" => "row-10000"}} =
             SupaCacherReplicator.get(dataset.tenant_id, dataset.table, 10_000)
  end

  test "refresh_row/2 updates the KV entry in place", %{dataset: dataset} do
    TestUtils.seed(dataset, TestUtils.rows(dataset, 2))
    {:ok, _} = SupaCacherReplicator.subscribe(dataset)

    TestUtils.seed(dataset, [%{"id" => 1, "name" => "updated"}, %{"id" => 2, "name" => "row-2"}])
    :ok = SupaCacherReplicator.refresh_row(dataset, 1)
    Subscription.await_loaded(dataset)

    assert {:ok, %{"name" => "updated"}} =
             SupaCacherReplicator.get(dataset.tenant_id, dataset.table, 1)

    assert {:ok, %{"name" => "row-2"}} =
             SupaCacherReplicator.get(dataset.tenant_id, dataset.table, 2)
  end

  test "refresh_row/2 removes an entry the origin no longer returns", %{dataset: dataset} do
    TestUtils.seed(dataset, TestUtils.rows(dataset, 2))
    {:ok, _} = SupaCacherReplicator.subscribe(dataset)

    TestUtils.seed(dataset, [%{"id" => 2, "name" => "row-2"}])
    :ok = SupaCacherReplicator.refresh_row(dataset, 1)
    Subscription.await_loaded(dataset)

    assert :miss = SupaCacherReplicator.get(dataset.tenant_id, dataset.table, 1)
  end

  test "delete_row/2 removes the KV entry", %{dataset: dataset} do
    TestUtils.seed(dataset, TestUtils.rows(dataset, 2))
    {:ok, _} = SupaCacherReplicator.subscribe(dataset)

    :ok = SupaCacherReplicator.delete_row(dataset, 2)
    Subscription.await_loaded(dataset)

    assert :miss = SupaCacherReplicator.get(dataset.tenant_id, dataset.table, 2)
    assert Subscription.primary_keys(dataset) == ["1"]
  end

  test "reconcile/1 removes stale entries and loads new ones", %{dataset: dataset} do
    TestUtils.seed(dataset, TestUtils.rows(dataset, 3))
    {:ok, _} = SupaCacherReplicator.subscribe(dataset)

    TestUtils.seed(dataset, [%{"id" => 1, "name" => "row-1"}, %{"id" => 4, "name" => "row-4"}])

    assert {:ok, 2} = SupaCacherReplicator.reconcile(dataset)

    assert :miss = SupaCacherReplicator.get(dataset.tenant_id, dataset.table, 2)
    assert :miss = SupaCacherReplicator.get(dataset.tenant_id, dataset.table, 3)

    assert {:ok, %{"name" => "row-4"}} =
             SupaCacherReplicator.get(dataset.tenant_id, dataset.table, 4)

    assert Enum.sort(Subscription.primary_keys(dataset)) == ["1", "4"]
  end

  test "rows without a primary key are skipped", %{dataset: dataset} do
    TestUtils.seed(dataset, [%{"name" => "no-pk"}, %{"id" => 1, "name" => "row-1"}])

    {:ok, _} = SupaCacherReplicator.subscribe(dataset)

    assert Subscription.primary_keys(dataset) == ["1"]
  end
end
