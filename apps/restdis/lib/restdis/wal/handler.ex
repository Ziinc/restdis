defmodule Restdis.Wal.Handler do
  @moduledoc """
  Behaviour a host implements to receive the decoded WAL events of a follower instance.

  The follower knows nothing of what a change means to the host: it hands each
  `Restdis.Wal.Event` to `c:handle_event/1` and acks the event's LSN when the
  handler returns `:ok`. A handler that applies events asynchronously returns
  `:defer` and acks each one itself with `Restdis.Wal.LsnStore.applied/2` once applied.
  """

  alias Restdis.Wal.Event
  alias Restdis.Wal.InstanceConfig
  alias Restdis.Wal.LsnStore

  @doc """
  Applies `event`. Returns `:ok` to have the follower ack its LSN, or `:defer` to ack it later.
  """
  @callback handle_event(Event.t()) :: :ok | :defer

  @doc """
  Hands `event` to the handler of the instance `name`, acking its LSN unless the handler defers.
  """
  @spec dispatch(atom(), Event.t()) :: :ok
  def dispatch(name, %Event{} = event) do
    case InstanceConfig.fetch!(name).handler.handle_event(event) do
      :ok -> LsnStore.applied(name, event.lsn)
      :defer -> :ok
    end
  end
end
