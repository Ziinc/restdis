defmodule RestdisReplicator.Application do
  @moduledoc """
  OTP application for the always-live table replication bounded context.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: RestdisReplicator.Registry},
      RestdisReplicator.Subscription.Supervisor,
      RestdisReplicator.Reconciler
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: RestdisReplicator.Supervisor
    )
  end
end
