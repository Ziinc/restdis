defmodule Restdis.Cache.Replication.Transport.Distribution do
  @moduledoc """
  Broadcasts replication messages to every connected peer over Erlang distribution.

  Delivery is asynchronous and best-effort: unreachable peers converge on their
  next `persist` write or on restart, when the disk cache is re-read.
  """

  @behaviour Restdis.Cache.Replication.Transport

  @impl Restdis.Cache.Replication.Transport
  def broadcast(receiver_name, message) do
    GenServer.abcast(Node.list(), receiver_name, {:sc_replication_stamped, message, now_us()})
    :ok
  end

  defp now_us, do: System.system_time(:microsecond)
end
