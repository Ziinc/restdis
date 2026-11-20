defmodule RestdisBuster.FanoutSubscriber do
  @moduledoc """
  Subscribes a node to the `wal_fanout` topic and dispatches received WAL events locally.
  """

  use GenServer

  alias Restdis.Wal.Event
  alias Restdis.Wal.Handler
  alias Restdis.Wal.InstanceConfig

  @doc """
  Starts the fanout subscriber for this node.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    az = InstanceConfig.fetch!(Restdis.Wal).az
    :syn.join(:wal_fanout, {:az, az}, self())
    {:ok, %{az: az}}
  end

  @impl GenServer
  def handle_info({:wal_event, %Event{} = event}, state) do
    Handler.dispatch(Restdis.Wal, event)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
