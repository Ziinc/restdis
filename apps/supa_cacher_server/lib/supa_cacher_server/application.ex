defmodule SupaCacherServer.Application do
  @moduledoc """
  OTP application for the protocol and rewarm bounded context.
  """

  use Application

  alias SupaCacherCache.ReadThrough
  alias SupaCacherServer.TenantConfig

  @impl Application
  def start(_type, _args) do
    resp_port = Application.get_env(:supa_cacher_server, :resp_port, 6380)

    resp_ip =
      :supa_cacher_server
      |> Application.get_env(:resp_listen_ip, :loopback)
      |> SupaCacherServer.Listener.parse_ip()

    http_port = Application.get_env(:supa_cacher_server, :http_port, 4040)

    children = [
      tenant_config_cache_spec(),
      TenantConfig.Cache,
      SupaCacherServer.PolicyStore,
      SupaCacherServer.Rewarm.Supervisor,
      {Finch, name: SupaCacherServer.Finch},
      {TelemetryMetricsPrometheus.Core,
       metrics: SupaCacherServer.Metrics.definitions(), name: :supa_cacher_prometheus},
      {:telemetry_poller,
       measurements: SupaCacherServer.Metrics.periodic_measurements(),
       period: :timer.seconds(10),
       name: :supa_cacher_poller},
      {ThousandIsland,
       port: resp_port,
       handler_module: SupaCacherServer.RESP.Handler,
       transport_options: [ip: resp_ip]},
      {Bandit, plug: SupaCacherServer.HTTP.Endpoint, port: http_port}
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: SupaCacherServer.Supervisor
    )
  end

  defp tenant_config_cache_spec do
    opts = Application.get_env(:supa_cacher_server, :tenant_config_cache, [])

    {ReadThrough,
     name: TenantConfig.Cache.cache_name(),
     data_dir: Keyword.get(opts, :data_dir, "./cache_data/control_plane"),
     ttl_ms: Keyword.get(opts, :ttl_ms, 60_000)}
  end
end
