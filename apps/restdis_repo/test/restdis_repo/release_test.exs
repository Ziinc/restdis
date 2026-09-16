defmodule RestdisRepo.ReleaseTest do
  use ExUnit.Case, async: false

  alias RestdisRepo.Release

  test "repos/0 returns the configured ecto repos" do
    assert Release.repos() == [RestdisRepo]
  end

  test "the repo migrations path resolves to the shipped migrations" do
    path = Ecto.Migrator.migrations_path(RestdisRepo)

    assert path == Path.join([Application.app_dir(:restdis_repo), "priv/repo", "migrations"])
    assert Path.wildcard(Path.join(path, "*.exs")) != []
  end

  test "migrate/0 runs all pending migrations for every configured repo" do
    assert Release.migrate() == :ok
  end

  test "rollback/2 rolls a repo back to the given version and forward again" do
    [last_version | _] =
      RestdisRepo
      |> Ecto.Migrator.migrations_path()
      |> Path.join("*.exs")
      |> Path.wildcard()
      |> Enum.map(&(&1 |> Path.basename() |> String.split("_") |> hd() |> String.to_integer()))
      |> Enum.sort(:desc)

    assert Release.rollback(RestdisRepo, last_version - 1) == :ok
    assert Release.migrate() == :ok
  end
end
