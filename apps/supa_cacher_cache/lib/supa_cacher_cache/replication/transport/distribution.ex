defmodule SupaCacherCache.Replication.Transport.Distribution do
  @moduledoc """
  Broadcasts replication messages to every connected peer over Erlang distribution.

  Delivery is asynchronous and best-effort: unreachable peers converge on their
  next `persist` write or on restart, when the disk cache is re-read.
  """

  @behaviour SupaCacherCache.Replication.Transport

  alias SupaCacherCache.Replication.Receiver

  @impl SupaCacherCache.Replication.Transport
  def broadcast(message) do
    GenServer.abcast(Node.list(), Receiver, message)
    :ok
  end
end
