defmodule SupaCacherCache.TestUtils.RecordingTransport do
  @moduledoc """
  Replication transport that forwards every broadcast to the capturing test process.
  """

  @behaviour SupaCacherCache.Replication.Transport

  alias SupaCacherCache.TestUtils

  @impl SupaCacherCache.Replication.Transport
  def broadcast(message) do
    case TestUtils.replication_target() do
      nil -> :ok
      pid -> send(pid, {:replicated, message})
    end

    :ok
  end
end
