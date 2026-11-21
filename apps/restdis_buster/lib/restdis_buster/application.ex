defmodule RestdisBuster.Application do
  @moduledoc """
  OTP application for the WAL ingestion and invalidation bounded context.
  """

  use Application

  alias Restdis.Cache.ReadThrough
  alias RestdisBuster.TenantTableConfig

  @impl Application
  def start(_type, _args) do
    children = [
      table_config_cache_spec(),
      RestdisBuster.Worker.Supervisor,
      RestdisBuster.Worker.CoalesceSweeper,
      {Restdis.Wal, wal_opts()}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: RestdisBuster.Supervisor)
  end

  # `wal_checkpoint` predates the library and lives in RestdisRepo's default schema.
  defp wal_opts do
    env = Application.get_all_env(:restdis_buster)

    [
      repo: Keyword.get(env, :repo, RestdisRepo),
      prefix: "public",
      slot_name: Keyword.get(env, :slot_name, "restdis_slot"),
      publication: Keyword.get(env, :publication_name, "restdis_pub"),
      replication: Keyword.get(env, :replication_connection, []),
      az: Keyword.get(env, :az, "local"),
      handler: RestdisBuster.WalHandler,
      on_takeover: {RestdisBuster.WalHandler, :on_takeover, []},
      telemetry_prefix: [:restdis_buster]
    ]
  end

  defp table_config_cache_spec do
    opts = Application.get_env(:restdis_buster, :tenant_table_config_cache, [])

    {ReadThrough,
     name: TenantTableConfig.Cache.cache_name(),
     data_dir: Keyword.get(opts, :data_dir, "./cache_data/control_plane"),
     ttl_ms: Keyword.get(opts, :ttl_ms, 60_000)}
  end
end
