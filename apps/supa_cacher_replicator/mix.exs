defmodule SupaCacherReplicator.MixProject do
  use Mix.Project

  def project do
    [
      app: :supa_cacher_replicator,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {SupaCacherReplicator.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:supa_cacher_cache, in_umbrella: true},
      {:supa_cacher_repo, in_umbrella: true},
      {:req, "~> 0.6"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.0"},
      {:stream_data, "~> 1.1", only: :test}
    ]
  end
end
