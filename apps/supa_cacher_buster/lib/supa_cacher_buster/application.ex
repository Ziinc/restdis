defmodule SupaCacherBuster.Application do
  use Application

  @impl Application
  def start(_type, _args) do
    :ok = :syn.add_node_to_scopes([:wal, :wal_fanout])

    children = [
      {DynamicSupervisor, name: SupaCacherBuster.TailerSupervisor, strategy: :one_for_one},
      SupaCacherBuster.TenantTableConfig.Cache,
      SupaCacherBuster.Worker.Supervisor,
      SupaCacherBuster.Worker.CoalesceSweeper,
      SupaCacherBuster.FanoutSubscriber,
      SupaCacherBuster.Infra.LsnStore,
      SupaCacherBuster.Singleton
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: SupaCacherBuster.Supervisor)
  end
end
