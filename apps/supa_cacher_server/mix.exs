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
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger],
      mod: {SupaCacherServer.Application, []}
    ]
  end

  defp deps do
    [
      {:restdis, path: "../restdis"},
      {:supa_cacher_replicator, in_umbrella: true},
      {:supa_cacher_repo, in_umbrella: true},
      {:libcluster, "~> 3.5"},
      {:thousand_island, "~> 1.5"},
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.16"},
      {:req, "~> 0.6"},
      {:finch, "~> 0.23"},
      {:jason, "~> 1.4"},
      {:telemetry_metrics, "~> 1.1"},
      {:telemetry_metrics_prometheus_core, "~> 1.2"},
      {:telemetry_poller, "~> 1.3"},
      {:opentelemetry_api, "~> 1.4"},
      {:opentelemetry, "~> 1.5"},
      {:opentelemetry_exporter, "~> 1.7"},
      {:opentelemetry_semantic_conventions, "~> 1.27"},
      {:otel_metric_exporter, "~> 0.3"},
      {:logger_json, "~> 6.2"},
      {:stream_data, "~> 1.1", only: :test}
    ]
  end
end
