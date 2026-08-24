defmodule SupaCacherBuster.Dispatcher do
  @moduledoc false

  alias SupaCacherBuster.Infra.SlotConfig
  alias SupaCacherBuster.WAL.Event

  @doc """
  Publishes a decoded WAL event to the `wal_fanout` topic for this availability zone.
  """
  @spec dispatch(Event.t()) :: :ok
  def dispatch(%Event{} = event) do
    az = SlotConfig.az()
    :syn.publish(:wal_fanout, {:az, az}, {:wal_event, event})
    :ok
  end
end
