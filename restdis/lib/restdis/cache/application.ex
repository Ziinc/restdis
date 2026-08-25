defmodule Restdis.Cache.Application do
  @moduledoc """
  OTP application for the cache bounded context.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Restdis.Cache.TenantRegistry},
      Restdis.Cache.TenantSupervisor,
      Restdis.Cache.Replication.Receiver
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Restdis.Cache.Supervisor)
  end
end
