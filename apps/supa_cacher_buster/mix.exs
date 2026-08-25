defmodule SupaCacherBuster.MixProject do
  use Mix.Project

  def project do
    [
      app: :supa_cacher_buster,
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
      mod: {SupaCacherBuster.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:restdis, path: "../../restdis"},
      {:supa_cacher_repo, in_umbrella: true},
      {:syn, "~> 3.3"},
      {:postgrex, "~> 0.17"},
      {:libcluster, "~> 3.4"},
      {:jason, "~> 1.4"},
      {:stream_data, "~> 1.1", only: :test}
    ]
  end
end
