defmodule RestdisReplicator.Reconciler do
  @moduledoc """
  Post-failover reconciliation: diffs every replicated dataset against PostgREST,
  staggered across tenants to avoid a thundering herd.
  """

  use GenServer

  require Logger

  alias RestdisReplicator.Dataset
  alias RestdisReplicator.Subscription
  alias RestdisReplicator.Subscription.Supervisor, as: SubscriptionSupervisor

  @default_stagger_ms 1_000

  @doc """
  Starts the reconciler.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Schedules a staggered reconciliation of every replicated dataset.
  """
  @spec reconcile_all() :: :ok
  def reconcile_all, do: GenServer.cast(__MODULE__, :reconcile_all)

  @doc """
  Reconciles every replicated dataset and returns the reconciled datasets.
  """
  @spec reconcile_all_sync() :: [Dataset.t()]
  def reconcile_all_sync, do: GenServer.call(__MODULE__, :reconcile_all_sync, :infinity)

  @impl GenServer
  def init(_opts), do: {:ok, %{}}

  @impl GenServer
  def handle_cast(:reconcile_all, state) do
    list_datasets()
    |> Enum.with_index()
    |> Enum.each(fn {dataset, index} ->
      Process.send_after(self(), {:reconcile, dataset}, index * stagger_ms())
    end)

    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:reconcile_all_sync, _from, state) do
    datasets = list_datasets()
    Enum.each(datasets, &reconcile/1)
    {:reply, datasets, state}
  end

  @impl GenServer
  def handle_info({:reconcile, %Dataset{} = dataset}, state) do
    reconcile(dataset)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp reconcile(%Dataset{} = dataset) do
    case SubscriptionSupervisor.ensure_started(dataset) do
      {:ok, _pid} ->
        Subscription.reconcile(dataset)

      {:error, reason} ->
        Logger.warning(
          "[RestdisReplicator] reconcile of #{dataset.table} failed: #{inspect(reason)}"
        )
    end
  end

  defp list_datasets do
    case Application.get_env(:restdis_replicator, :dataset_source) do
      {mod, fun, args} -> apply(mod, fun, args)
      nil -> []
    end
  end

  defp stagger_ms do
    Application.get_env(:restdis_replicator, :reconcile_stagger_ms, @default_stagger_ms)
  end
end
