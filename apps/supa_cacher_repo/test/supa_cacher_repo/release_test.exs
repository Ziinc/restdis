defmodule SupaCacherRepo.ReleaseTest do
  use ExUnit.Case, async: true

  alias SupaCacherRepo.Release

  test "repos/0 returns the configured ecto repos" do
    assert Release.repos() == [SupaCacherRepo]
  end

  test "migrations are shipped in the app priv directory" do
    path = Path.join([Application.app_dir(:supa_cacher_repo), "priv", "repo", "migrations"])

    assert File.dir?(path)
    assert Path.wildcard(Path.join(path, "*.exs")) != []
  end
end
