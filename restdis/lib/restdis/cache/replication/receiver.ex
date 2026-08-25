defmodule Restdis.Cache.Replication.Receiver do
  @moduledoc """
  Node-local endpoint for inbound disk cache replication messages.
  """

  use GenServer

  alias Restdis.Cache.Replication

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
  def handle_cast(
        {:sc_replication_stamped, {:sc_replication, tenant_id, _event} = message, sent_at_us},
        state
      ) do
    lag_us = max(System.system_time(:microsecond) - sent_at_us, 0)

    :telemetry.execute([:restdis, :replication, :lag], %{lag_us: lag_us}, %{
      tenant_id: tenant_id
    })

    handle_cast(message, state)
  end

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
