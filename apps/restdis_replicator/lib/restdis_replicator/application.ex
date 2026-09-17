defmodule RestdisReplicator.Application do
  @moduledoc """
  OTP application for the always-live table replication bounded context.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      cache_spec(),
      {Registry, keys: :unique, name: RestdisReplicator.Registry},
      RestdisReplicator.Subscription.Supervisor,
      RestdisReplicator.Reconciler
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: RestdisReplicator.Supervisor
    )
  end

  defp cache_spec do
    {Restdis.Cache,
     data_dir: Application.get_env(:restdis_replicator, :cache_data_dir, "./cache_data"),
     origin: Application.get_env(:restdis_replicator, :cache_origin, Restdis.Cache.Origin.Stub),
     repo: RestdisRepo,
     prefix: "restdis"}
  end
end
