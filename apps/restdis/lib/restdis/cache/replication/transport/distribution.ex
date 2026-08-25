defmodule Restdis.Cache.Replication.Transport.Distribution do
  @moduledoc """
  Broadcasts replication messages to every connected peer over Erlang distribution.

  Delivery is asynchronous and best-effort: unreachable peers converge on their
  next `persist` write or on restart, when the disk cache is re-read.
  """

  @behaviour Restdis.Cache.Replication.Transport

  alias Restdis.Cache.Replication.Receiver

  @impl Restdis.Cache.Replication.Transport
  def broadcast(message) do
    GenServer.abcast(Node.list(), Receiver, {:sc_replication_stamped, message, now_us()})
    :ok
  end

  defp now_us, do: System.system_time(:microsecond)
end
