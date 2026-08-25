defmodule RestdisRepo do
  @moduledoc """
  Ecto repository for Restdis control-plane tables.
  """

  use Ecto.Repo,
    otp_app: :restdis_repo,
    adapter: Ecto.Adapters.Postgres
end
