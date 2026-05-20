defmodule SupaCacherBuster.FanoutSubscriber do
  use GenServer

  alias SupaCacherBuster.Infra.SlotConfig
  alias SupaCacherBuster.WAL.Event
  alias SupaCacherBuster.Worker.Supervisor, as: WorkerSupervisor

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    az = SlotConfig.az()
    :syn.join(:wal_fanout, {:az, az}, self())
    {:ok, %{az: az}}
  end

  @impl GenServer
  def handle_info({:wal_event, %Event{} = event}, state) do
    WorkerSupervisor.start_worker(event)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
