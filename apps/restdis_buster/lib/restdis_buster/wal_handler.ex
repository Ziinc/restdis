defmodule RestdisBuster.WalHandler do
  @moduledoc """
  `Restdis.Wal.Handler` of the `Restdis.Wal` instance: runs each event in a
  `RestdisBuster.Worker`, which acks the event's LSN once it is applied.
  """

  @behaviour Restdis.Wal.Handler

  alias RestdisBuster.Worker.Supervisor, as: WorkerSupervisor

  @impl Restdis.Wal.Handler
  def handle_event(event) do
    WorkerSupervisor.start_worker(event)
    :defer
  end
end
