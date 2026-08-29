defmodule Restdis.TestRepo do
  @moduledoc """
  Ecto repo used only by the library's own test suite to exercise
  `Restdis.Migration` the way a host application would: by injecting a repo
  it owns. The library itself never defines a repo (see LIB_PRD.md).
  """

  use Ecto.Repo,
    otp_app: :restdis,
    adapter: Ecto.Adapters.Postgres
end
