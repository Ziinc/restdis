defmodule RestdisRepo.ReleaseTest do
  use ExUnit.Case, async: true

  alias RestdisRepo.Release

  test "repos/0 returns the configured ecto repos" do
    assert Release.repos() == [RestdisRepo]
  end

  test "the repo migrations path resolves to the shipped migrations" do
    path = Ecto.Migrator.migrations_path(RestdisRepo)

    assert path == Path.join([Application.app_dir(:restdis_repo), "priv/repo", "migrations"])
    assert Path.wildcard(Path.join(path, "*.exs")) != []
  end
end
