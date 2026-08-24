defmodule SupaCacherCache.Replication.Receiver do
  @moduledoc """
  Node-local endpoint for inbound disk cache replication messages.
  """

  use GenServer

  alias SupaCacherCache.Replication

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    {:ok, %{}}
  end

  @impl GenServer
  def handle_cast({:sc_replication, tenant_id, event}, state) do
    _ = Replication.apply_event(tenant_id, event)
    {:noreply, state}
  end

  def handle_cast(_message, state), do: {:noreply, state}

  @impl GenServer
  def handle_call(:sync, _from, state) do
    {:reply, :ok, state}
  end
end
