defmodule Restdis.MixProject do
  use Mix.Project

  @umbrella_namespaces ~w(SupaCacherServer SupaCacherBuster SupaCacherRepo)

  def project do
    [
      app: :restdis,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Restdis.Cache.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:cubdb, "~> 2.0"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.1", only: :test}
    ]
  end

  defp aliases do
    [
      check: ["check.compile", "check.format", "check.lint", "check.boundary"],
      "check.compile": ["compile --force --warnings-as-errors"],
      "check.format": ["format --check-formatted"],
      "check.lint": ["credo --strict --config-file .credo.exs"],
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
        Mix.raise("restdis must not reference the host application.\n" <> Enum.join(lines, "\n"))
    end
  end
end
