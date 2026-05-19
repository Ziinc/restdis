defmodule SupaCacherRepo.Application do
  use Application

  @impl Application
  def start(_type, _args) do
    children = [SupaCacherRepo]
    Supervisor.start_link(children, strategy: :one_for_one, name: SupaCacherRepo.Supervisor)
  end
end
