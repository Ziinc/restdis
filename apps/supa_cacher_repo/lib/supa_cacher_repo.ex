defmodule SupaCacherRepo do
  @moduledoc """
  Ecto repository for SupaCacher control-plane tables.
  """

  use Ecto.Repo,
    otp_app: :supa_cacher_repo,
    adapter: Ecto.Adapters.Postgres
end
