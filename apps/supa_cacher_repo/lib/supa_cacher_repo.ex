defmodule SupaCacherRepo do
  use Ecto.Repo,
    otp_app: :supa_cacher_repo,
    adapter: Ecto.Adapters.Postgres
end
