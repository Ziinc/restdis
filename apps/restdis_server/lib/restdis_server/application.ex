defmodule RestdisServer.Application do
  @moduledoc """
  OTP application for the protocol and rewarm bounded context.
  """

  use Application

  alias Restdis.Cache.ReadThrough
  alias RestdisServer.TenantConfig

  @impl Application
  def start(_type, _args) do
    resp_port = Application.get_env(:restdis_server, :resp_port, 6380)

    resp_ip =
      :restdis_server
      |> Application.get_env(:resp_listen_ip, :loopback)
      |> RestdisServer.Listener.parse_ip()

    http_port = Application.get_env(:restdis_server, :http_port, 4040)

    children =
      cluster_formation() ++
        [
          Restdis.Cache,
          RestdisElectric,
          tenant_config_cache_spec(),
          TenantConfig.Cache,
          RestdisServer.PolicyStore,
          RestdisServer.Rewarm.Supervisor,
          {Finch, name: RestdisServer.Finch},
          {TelemetryMetricsPrometheus.Core,
           metrics: RestdisServer.Metrics.definitions(), name: :restdis_prometheus},
          {:telemetry_poller,
           measurements: RestdisServer.Metrics.periodic_measurements(),
           period: :timer.seconds(10),
           name: :restdis_poller},
          {ThousandIsland,
           port: resp_port,
           handler_module: RestdisServer.RESP.Handler,
           transport_options: [ip: resp_ip]},
          {Bandit, plug: RestdisServer.HTTP.Endpoint, port: http_port}
        ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: RestdisServer.Supervisor
    )
  end

  defp cluster_formation do
    case Application.get_env(:restdis_server, :topologies, []) do
      [] ->
        []

      topologies ->
        [{Cluster.Supervisor, [topologies, [name: RestdisServer.ClusterFormation]]}]
    end
  end

  defp tenant_config_cache_spec do
    opts = Application.get_env(:restdis_server, :tenant_config_cache, [])

    {ReadThrough,
     name: TenantConfig.Cache.cache_name(),
     data_dir: Keyword.get(opts, :data_dir, "./cache_data/control_plane"),
     ttl_ms: Keyword.get(opts, :ttl_ms, 60_000)}
  end
end
