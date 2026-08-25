defmodule RestdisRepo.Application do
  @moduledoc """
  OTP application supervising the Ecto repository.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    children = [RestdisRepo]
    Supervisor.start_link(children, strategy: :one_for_one, name: RestdisRepo.Supervisor)
  end
end
