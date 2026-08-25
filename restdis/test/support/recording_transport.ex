defmodule Restdis.Cache.TestUtils.RecordingTransport do
  @moduledoc """
  Replication transport that forwards every broadcast to the capturing test process.
  """

  @behaviour Restdis.Cache.Replication.Transport

  alias Restdis.Cache.TestUtils

  @impl Restdis.Cache.Replication.Transport
  def broadcast(message) do
    case TestUtils.replication_target() do
      nil -> :ok
      pid -> send(pid, {:replicated, message})
    end

    :ok
  end
end
