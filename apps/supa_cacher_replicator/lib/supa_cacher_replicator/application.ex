defmodule SupaCacherReplicator.Application do
  @moduledoc """
  OTP application for the always-live table replication bounded context.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: SupaCacherReplicator.Registry},
      SupaCacherReplicator.Subscription.Supervisor,
      SupaCacherReplicator.Reconciler
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: SupaCacherReplicator.Supervisor
    )
  end
end
