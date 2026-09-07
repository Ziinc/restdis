defmodule RestdisUmbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      dialyzer: [
        plt_add_apps: [:mix],
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"}
      ],
      releases: releases()
    ]
  end

  defp releases do
    [
      restdis: [
        include_executables_for: [:unix],
        applications: [
          restdis_repo: :permanent,
          restdis: :permanent,
          restdis_electric: :permanent,
          restdis_replicator: :permanent,
          restdis_server: :permanent,
          restdis_buster: :permanent
        ]
      ]
    ]
  end

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.5", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      check: [
        "check.compile",
        "check.format",
        "check.lint",
        "check.dialyzer",
        "check.sobelow"
      ],
      "check.compile": ["compile --force --warnings-as-errors"],
      "check.format": ["format --check-formatted"],
      "check.lint": ["credo --strict", "check.ast_grep"],
      "check.ast_grep": &ast_grep/1,
      "check.dialyzer": ["dialyzer"],
      "check.sobelow": ["sobelow --exit"]
    ]
  end

  defp ast_grep(_args) do
    case System.cmd("ast-grep", ["scan"], into: IO.stream(:stdio, :line)) do
      {_output, 0} -> :ok
      {_output, status} -> Mix.raise("ast-grep scan failed with exit status #{status}")
    end
  rescue
    ErlangError ->
      Mix.raise("ast-grep is not installed. Install it with: npm install -g @ast-grep/cli")
  end
end
