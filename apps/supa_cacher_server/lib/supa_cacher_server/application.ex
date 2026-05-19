defmodule SupaCacherServer.Application do
  use Application

  @impl Application
  def start(_type, _args) do
    resp_port = Application.get_env(:supa_cacher_server, :resp_port, 6380)
    http_port = Application.get_env(:supa_cacher_server, :http_port, 4040)

    children = [
      SupaCacherServer.TenantConfig.Cache,
      SupaCacherServer.PolicyStore,
      {Finch, name: SupaCacherServer.Finch},
      {ThousandIsland,
       port: resp_port,
       handler_module: SupaCacherServer.RESP.Handler,
       transport_options: [ip: :loopback]},
      {Bandit, plug: SupaCacherServer.HTTP.Endpoint, port: http_port}
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: SupaCacherServer.Supervisor
    )
  end
end
