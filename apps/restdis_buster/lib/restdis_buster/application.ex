defmodule RestdisBuster.Application do
  @moduledoc """
  OTP application for the WAL ingestion and invalidation bounded context.
  """

  use Application

  alias Restdis.Cache.ReadThrough
  alias RestdisBuster.TenantTableConfig

  @impl Application
  def start(_type, _args) do
    :ok = :syn.add_node_to_scopes([:wal, :wal_fanout])

    children = [
      cache_spec(),
      {DynamicSupervisor, name: RestdisBuster.TailerSupervisor, strategy: :one_for_one},
      table_config_cache_spec(),
      RestdisBuster.Worker.Supervisor,
      RestdisBuster.Worker.CoalesceSweeper,
      RestdisBuster.FanoutSubscriber,
      RestdisBuster.Infra.LsnStore,
      RestdisBuster.Singleton
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: RestdisBuster.Supervisor)
  end

  defp cache_spec do
    {Restdis.Cache,
     data_dir: Application.get_env(:restdis_buster, :cache_data_dir, "./cache_data"),
     origin: Application.get_env(:restdis_buster, :cache_origin, Restdis.Cache.Origin.Stub),
     repo: RestdisRepo,
     prefix: "restdis"}
  end

  defp table_config_cache_spec do
    opts = Application.get_env(:restdis_buster, :tenant_table_config_cache, [])

    {ReadThrough,
     name: TenantTableConfig.Cache.cache_name(),
     data_dir: Keyword.get(opts, :data_dir, "./cache_data/control_plane"),
     ttl_ms: Keyword.get(opts, :ttl_ms, 60_000)}
  end
end
