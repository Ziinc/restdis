defmodule SupaCacherServer.MixProject do
  use Mix.Project

  def project do
    [
      app: :supa_cacher_server,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {SupaCacherServer.Application, []}
    ]
  end

  defp deps do
    [
      {:supa_cacher_cache, in_umbrella: true},
      {:supa_cacher_repo, in_umbrella: true},
      {:thousand_island, "~> 1.3"},
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.16"},
      {:req, "~> 0.5"},
      {:finch, "~> 0.18"},
      {:jason, "~> 1.4"},
      {:stream_data, "~> 1.1", only: :test}
    ]
  end
end
