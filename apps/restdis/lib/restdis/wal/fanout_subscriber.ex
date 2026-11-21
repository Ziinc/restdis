defmodule Restdis.Wal.FanoutSubscriber do
  @moduledoc """
  Subscribes a node to an instance's `wal_fanout` topic and hands received WAL events to its handler.
  """

  use GenServer

  alias Restdis.Wal.Event
  alias Restdis.Wal.Handler
  alias Restdis.Wal.InstanceConfig

  @doc """
  Starts this node's fanout subscriber for the instance `opts[:name]`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, name, name: Module.concat(name, FanoutSubscriber))
  end

  @impl GenServer
  def init(name) do
    az = InstanceConfig.fetch!(name).az
    :syn.join(:wal_fanout, {name, az}, self())
    {:ok, %{name: name, az: az}}
  end

  @impl GenServer
  def handle_info({:wal_event, %Event{} = event}, state) do
    Handler.dispatch(state.name, event)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
