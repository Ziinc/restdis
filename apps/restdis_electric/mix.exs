defmodule RestdisElectric.MixProject do
  use Mix.Project

  @umbrella_namespaces ~w(RestdisServer RestdisBuster RestdisRepo RestdisReplicator)

  def project do
    [
      app: :restdis_electric,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.json": :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:restdis, in_umbrella: true},
      {:rustler, "~> 0.38"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.0"},
      {:req, "~> 0.6"},
      {:ecto_sql, "~> 3.13"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:postgrex, "~> 0.22"},
      {:stream_data, "~> 1.1", only: :test}
    ]
  end

  defp aliases do
    [
      check: ["check.compile", "check.format", "check.lint", "check.boundary"],
      "check.compile": ["compile --force --warnings-as-errors"],
      "check.format": ["format --check-formatted"],
      "check.lint": ["credo --strict"],
      "check.boundary": &boundary/1
    ]
  end

  defp boundary(_args) do
    pattern = Enum.join(@umbrella_namespaces, "|")

    offenders =
      Path.wildcard("lib/**/*.ex")
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _no} -> Regex.match?(~r/\b(#{pattern})\b/, line) end)
        |> Enum.map(fn {line, no} -> "#{path}:#{no}: #{String.trim(line)}" end)
      end)

    case offenders do
      [] ->
        :ok

      lines ->
        Mix.raise(
          "restdis_electric must not reference other umbrella applications.\n" <>
            Enum.join(lines, "\n")
        )
    end
  end
end
