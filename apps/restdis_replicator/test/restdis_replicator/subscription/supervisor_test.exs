defmodule RestdisReplicator.Subscription.SupervisorTest do
  use ExUnit.Case, async: false

  alias RestdisReplicator.Subscription.Supervisor, as: SubscriptionSupervisor
  alias RestdisReplicator.TestUtils

  setup do
    dataset = TestUtils.dataset()
    on_exit(fn -> TestUtils.cleanup(dataset) end)
    {:ok, dataset: dataset}
  end

  test "whereis/1 returns nil when no subscription is running", %{dataset: dataset} do
    assert SubscriptionSupervisor.whereis(dataset) == nil
  end

  test "stop/1 is a no-op when no subscription is running", %{dataset: dataset} do
    assert SubscriptionSupervisor.stop(dataset) == :ok
  end

  test "ensure_started/1 is idempotent when called concurrently", %{dataset: dataset} do
    results =
      1..10
      |> Enum.map(fn _ ->
        Task.async(fn -> SubscriptionSupervisor.ensure_started(dataset) end)
      end)
      |> Enum.map(&Task.await/1)

    pids =
      results
      |> Enum.map(fn {:ok, pid} -> pid end)
      |> Enum.uniq()

    assert length(pids) == 1
    assert Enum.all?(results, &match?({:ok, _pid}, &1))
  end
end
