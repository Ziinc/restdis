defmodule RestdisReplicator do
  @moduledoc """
  Public API of the replication bounded context: subscriptions and KV row reads.
  """

  alias RestdisReplicator.Dataset
  alias RestdisReplicator.Reconciler
  alias RestdisReplicator.Subscription
  alias RestdisReplicator.Subscription.Supervisor, as: SubscriptionSupervisor

  @doc """
  Subscribes to `attrs`, loading the full result set into the cache as KV pairs.
  """
  @spec subscribe(map() | Dataset.t()) :: {:ok, Dataset.t()} | {:error, term()}
  def subscribe(attrs) do
    dataset = Dataset.new(attrs)

    case SubscriptionSupervisor.ensure_started(dataset) do
      {:ok, _pid} ->
        Subscription.await_loaded(dataset)
        {:ok, dataset}

      error ->
        error
    end
  end

  @doc """
  Stops the subscription of `attrs` without removing its KV entries.
  """
  @spec unsubscribe(map() | Dataset.t()) :: :ok
  def unsubscribe(attrs), do: SubscriptionSupervisor.stop(Dataset.new(attrs))

  @doc """
  Returns true when a subscription for `attrs` is running.
  """
  @spec subscribed?(map() | Dataset.t()) :: boolean()
  def subscribed?(attrs), do: not is_nil(SubscriptionSupervisor.whereis(Dataset.new(attrs)))

  @doc """
  Reads the replicated row `pk` of `table` from the cache.
  """
  @spec get(String.t(), String.t(), term()) :: {:ok, map()} | :miss
  def get(tenant_id, table, pk) do
    Restdis.Cache.peek(tenant_id, Dataset.cache_key(table, pk))
  end

  @doc """
  Re-fetches the row `pk` of `attrs` from the origin and updates it in place.
  """
  @spec refresh_row(map() | Dataset.t(), term()) :: :ok | {:error, term()}
  def refresh_row(attrs, pk) do
    with {:ok, dataset} <- ensure_subscribed(attrs) do
      Subscription.refresh_row(dataset, pk)
    end
  end

  @doc """
  Removes the KV entry of the row `pk` of `attrs`.
  """
  @spec delete_row(map() | Dataset.t(), term()) :: :ok | {:error, term()}
  def delete_row(attrs, pk) do
    with {:ok, dataset} <- ensure_subscribed(attrs) do
      Subscription.delete_row(dataset, pk)
    end
  end

  @doc """
  Diffs `attrs` against the origin, removing entries that no longer exist.
  """
  @spec reconcile(map() | Dataset.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def reconcile(attrs) do
    with {:ok, dataset} <- ensure_subscribed(attrs) do
      Subscription.reconcile(dataset)
    end
  end

  @doc """
  Schedules a staggered reconciliation of every replicated dataset.
  """
  @spec reconcile_all() :: :ok
  defdelegate reconcile_all(), to: Reconciler

  defp ensure_subscribed(attrs) do
    dataset = Dataset.new(attrs)

    case SubscriptionSupervisor.ensure_started(dataset) do
      {:ok, _pid} -> {:ok, dataset}
      error -> error
    end
  end
end
