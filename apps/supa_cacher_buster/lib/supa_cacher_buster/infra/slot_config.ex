defmodule SupaCacherBuster.Infra.SlotConfig do
  @moduledoc false

  @doc """
  Returns the configured replication slot name.
  """
  @spec slot_name() :: String.t()
  def slot_name do
    Application.get_env(:supa_cacher_buster, :slot_name, "supacacher_slot")
  end

  @doc """
  Returns the configured publication name.
  """
  @spec publication_name() :: String.t()
  def publication_name do
    Application.get_env(:supa_cacher_buster, :publication_name, "supacacher_pub")
  end

  @doc """
  Returns this node's availability zone, used as the fanout topic scope.
  """
  @spec az() :: String.t()
  def az do
    Application.get_env(:supa_cacher_buster, :az, "local")
  end

  @doc """
  Returns the connection options for the replication connection.
  """
  @spec replication_conn_opts() :: keyword()
  def replication_conn_opts do
    Application.get_env(:supa_cacher_buster, :replication_connection, [])
  end
end
