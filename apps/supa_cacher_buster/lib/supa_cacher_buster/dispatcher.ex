defmodule SupaCacherBuster.Dispatcher do
  @moduledoc false

  alias SupaCacherBuster.Infra.SlotConfig
  alias SupaCacherBuster.WAL.Event

  @spec dispatch(Event.t()) :: :ok
  def dispatch(%Event{} = event) do
    az = SlotConfig.az()
    :syn.publish(:wal_fanout, {:az, az}, {:wal_event, event})
    :ok
  end
end
