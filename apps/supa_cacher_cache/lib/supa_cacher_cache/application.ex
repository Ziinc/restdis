defmodule SupaCacherCache.Application do
  @moduledoc """
  OTP application for the cache bounded context.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: SupaCacherCache.TenantRegistry},
      SupaCacherCache.TenantSupervisor,
      SupaCacherCache.Replication.Receiver
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: SupaCacherCache.Supervisor)
  end
end
