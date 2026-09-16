defmodule Restdis.Cache.Replication.Receiver do
  @moduledoc """
  Node-local endpoint for inbound disk cache replication messages.

  Scoped by cache instance `name`, so a second `Restdis.Cache` instance in the
  same VM gets its own registered receiver rather than colliding with the first.
  """

  use GenServer

  alias Restdis.Cache.Replication

  @doc """
  Returns the registered name of the replication receiver belonging to instance `name`.
  """
  @spec process_name(atom()) :: atom()
  def process_name(name), do: Module.concat(name, __MODULE__)

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: process_name(name))
  end

  @impl GenServer
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    {:ok, %{name: name}}
  end

  @impl GenServer
  def handle_cast(
        {:sc_replication_stamped, {:sc_replication, _name, tenant_id, _event} = message,
         sent_at_us},
        state
      ) do
    lag_us = max(System.system_time(:microsecond) - sent_at_us, 0)

    :telemetry.execute([:restdis, :replication, :lag], %{lag_us: lag_us}, %{
      tenant_id: tenant_id
    })

    handle_cast(message, state)
  end

  def handle_cast({:sc_replication, name, tenant_id, event}, state) do
    _ = Replication.apply_event(name, tenant_id, event)
    {:noreply, state}
  end

  def handle_cast(_message, state), do: {:noreply, state}

  @impl GenServer
  def handle_call(:sync, _from, state) do
    {:reply, :ok, state}
  end
end
