defmodule SupaCacherBuster.Application do
  @moduledoc """
  OTP application for the WAL ingestion and invalidation bounded context.
  """

  use Application

  alias Restdis.Cache.ReadThrough
  alias SupaCacherBuster.TenantTableConfig

  @impl Application
  def start(_type, _args) do
    :ok = :syn.add_node_to_scopes([:wal, :wal_fanout])

    children = [
      {DynamicSupervisor, name: SupaCacherBuster.TailerSupervisor, strategy: :one_for_one},
      table_config_cache_spec(),
      SupaCacherBuster.Worker.Supervisor,
      SupaCacherBuster.Worker.CoalesceSweeper,
      SupaCacherBuster.FanoutSubscriber,
      SupaCacherBuster.Infra.LsnStore,
      SupaCacherBuster.Singleton
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: SupaCacherBuster.Supervisor)
  end

  defp table_config_cache_spec do
    opts = Application.get_env(:supa_cacher_buster, :tenant_table_config_cache, [])

    {ReadThrough,
     name: TenantTableConfig.Cache.cache_name(),
     data_dir: Keyword.get(opts, :data_dir, "./cache_data/control_plane"),
     ttl_ms: Keyword.get(opts, :ttl_ms, 60_000)}
  end
end
