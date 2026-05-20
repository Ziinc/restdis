defmodule SupaCacherBuster.Infra.SlotConfig do
  @moduledoc false

  @spec slot_name() :: String.t()
  def slot_name do
    Application.get_env(:supa_cacher_buster, :slot_name, "supacacher_slot")
  end

  @spec publication_name() :: String.t()
  def publication_name do
    Application.get_env(:supa_cacher_buster, :publication_name, "supacacher_pub")
  end

  @spec az() :: String.t()
  def az do
    Application.get_env(:supa_cacher_buster, :az, "local")
  end

  @spec replication_conn_opts() :: keyword()
  def replication_conn_opts do
    Application.get_env(:supa_cacher_buster, :replication_connection, [])
  end
end
