defmodule SupaCacherRepo.Release do
  @moduledoc """
  Migration entrypoints for the assembled release, where Mix is unavailable.
  """

  @app :supa_cacher_repo

  @doc "Repos configured for migration."
  @spec repos() :: [module()]
  def repos, do: Application.fetch_env!(@app, :ecto_repos)

  @doc "Runs all pending migrations for every configured repo."
  @spec migrate() :: :ok
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc "Rolls `repo` back to `version`."
  @spec rollback(module(), non_neg_integer()) :: :ok
  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
    :ok
  end

  defp load_app do
    Application.load(@app)
  end
end
