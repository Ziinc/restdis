defmodule RestdisBuster.Dispatcher do
  @moduledoc false

  alias RestdisBuster.Infra.SlotConfig
  alias RestdisBuster.WAL.Event

  @doc """
  Publishes a decoded WAL event to the `wal_fanout` topic for every known
  availability zone, so that all AZs in the cluster mesh receive the WAL
  event, not just the AZ of the dispatching node.

  Known AZs are discovered from the `:wal_fanout` `:syn` scope's group
  names: every `RestdisBuster.FanoutSubscriber` joins `{:az, az}` for its
  own AZ in that scope, and `:syn` replicates group membership across all
  connected nodes, so `:syn.group_names/1` returns the full set of AZs
  currently represented anywhere in the cluster. In a single-AZ deployment
  this returns just the local AZ, preserving prior behavior.
  """
  @spec dispatch(Event.t()) :: :ok
  def dispatch(%Event{} = event) do
    for az <- known_azs() do
      :syn.publish(:wal_fanout, {:az, az}, {:wal_event, event})
    end

    :ok
  end

  @spec known_azs() :: [String.t()]
  defp known_azs do
    case :syn.group_names(:wal_fanout) do
      [] -> [SlotConfig.az()]
      groups -> for {:az, az} <- groups, do: az
    end
  end
end
