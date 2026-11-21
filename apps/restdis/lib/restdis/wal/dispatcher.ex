defmodule Restdis.Wal.Dispatcher do
  @moduledoc false

  alias Restdis.Wal.Event
  alias Restdis.Wal.InstanceConfig

  @doc """
  Publishes a decoded WAL event of the instance `name` to the `wal_fanout`
  topic for every known availability zone, so that all AZs in the cluster
  mesh receive the WAL event, not just the AZ of the dispatching node.

  Known AZs are discovered from the `:wal_fanout` `:syn` scope's group
  names: every `Restdis.Wal.FanoutSubscriber` joins `{name, az}` for its
  own AZ in that scope, and `:syn` replicates group membership across all
  connected nodes, so `:syn.group_names/1` returns the full set of AZs
  currently represented anywhere in the cluster. In a single-AZ deployment
  this returns just the local AZ, preserving prior behavior.
  """
  @spec dispatch(atom(), Event.t()) :: :ok
  def dispatch(name, %Event{} = event) do
    for az <- known_azs(name) do
      :syn.publish(:wal_fanout, {name, az}, {:wal_event, event})
    end

    :ok
  end

  @spec known_azs(atom()) :: [String.t()]
  defp known_azs(name) do
    case for({^name, az} <- :syn.group_names(:wal_fanout), do: az) do
      [] -> [InstanceConfig.fetch!(name).az]
      azs -> azs
    end
  end
end
