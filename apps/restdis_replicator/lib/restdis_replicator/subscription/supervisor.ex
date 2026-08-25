defmodule RestdisReplicator.Subscription.Supervisor do
  @moduledoc """
  Dynamic supervisor starting one subscription per replicated dataset.
  """

  use DynamicSupervisor

  alias RestdisReplicator.Dataset
  alias RestdisReplicator.Subscription

  @doc """
  Starts the supervisor of the dataset subscriptions.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl DynamicSupervisor
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts the subscription of `dataset` unless it is already running.
  """
  @spec ensure_started(Dataset.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(%Dataset{} = dataset) do
    case whereis(dataset) do
      nil ->
        case DynamicSupervisor.start_child(__MODULE__, {Subscription, dataset}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          error -> error
        end

      pid ->
        {:ok, pid}
    end
  end

  @doc """
  Stops the subscription of `dataset`.
  """
  @spec stop(Dataset.t()) :: :ok
  def stop(%Dataset{} = dataset) do
    case whereis(dataset) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(__MODULE__, pid)
    end

    :ok
  end

  @doc """
  Returns the pid of the subscription of `dataset`, or nil.
  """
  @spec whereis(Dataset.t()) :: pid() | nil
  def whereis(%Dataset{} = dataset) do
    case Registry.lookup(RestdisReplicator.Registry, Dataset.registry_key(dataset)) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end
end
