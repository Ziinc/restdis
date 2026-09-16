defmodule RestdisReplicator.SubscriptionErrorTest do
  @moduledoc """
  Exercises the error branches of `RestdisReplicator.Subscription` by swapping the
  configured origin for `RestdisReplicator.Origin.PostgREST` with no tenant config
  lookup configured, which makes every origin call fail deterministically.
  """

  use ExUnit.Case, async: false

  alias RestdisReplicator.Subscription
  alias RestdisReplicator.TestUtils

  setup do
    dataset = TestUtils.dataset()
    previous_origin = Application.get_env(:restdis_replicator, :origin)
    Application.put_env(:restdis_replicator, :origin, RestdisReplicator.Origin.PostgREST)

    on_exit(fn ->
      TestUtils.cleanup(dataset)
      Application.put_env(:restdis_replicator, :origin, previous_origin)
    end)

    {:ok, dataset: dataset}
  end

  test "initial load logs a warning and keeps the subscription empty on error", %{
    dataset: dataset
  } do
    assert {:ok, ^dataset} = RestdisReplicator.subscribe(dataset)

    assert Subscription.primary_keys(dataset) == []
    assert :miss = RestdisReplicator.get(dataset.tenant_id, dataset.table, 1)
  end

  test "refresh_row/2 logs a warning and leaves state unchanged on error", %{dataset: dataset} do
    {:ok, ^dataset} = RestdisReplicator.subscribe(dataset)

    assert :ok = RestdisReplicator.refresh_row(dataset, 1)
    Subscription.await_loaded(dataset)

    assert Subscription.primary_keys(dataset) == []
  end

  test "reconcile/1 returns the origin error", %{dataset: dataset} do
    {:ok, ^dataset} = RestdisReplicator.subscribe(dataset)

    assert {:error, :no_tenant_config_lookup} = RestdisReplicator.reconcile(dataset)
  end
end
