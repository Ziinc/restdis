defmodule SupaCacherRepo.ReleaseTest do
  use ExUnit.Case, async: true

  alias SupaCacherRepo.Release

  test "repos/0 returns the configured ecto repos" do
    assert Release.repos() == [SupaCacherRepo]
  end

  test "the repo migrations path resolves to the shipped migrations" do
    path = Ecto.Migrator.migrations_path(SupaCacherRepo)

    assert path == Path.join([Application.app_dir(:supa_cacher_repo), "priv/repo", "migrations"])
    assert Path.wildcard(Path.join(path, "*.exs")) != []
  end
end
