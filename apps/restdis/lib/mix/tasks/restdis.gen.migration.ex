defmodule Mix.Tasks.Restdis.Gen.Migration do
  use Mix.Task

  import Mix.Generator
  import Mix.Ecto
  import Mix.EctoSQL

  alias Restdis.Migrations.Postgres

  @shortdoc "Generates a migration that installs the restdis library's tables"

  @aliases [
    r: :repo,
    p: :prefix
  ]

  @switches [
    repo: [:string, :keep],
    prefix: :string,
    version: :integer,
    migrations_path: :string,
    no_compile: :boolean,
    no_deps_check: :boolean
  ]

  @moduledoc """
  Generates the one host migration a consumer of the `restdis` library needs
  to install its control-plane tables.

  The repository must be set under `:ecto_repos` in the current app
  configuration or given via the `-r` / `--repo` option.

      $ mix restdis.gen.migration
      $ mix restdis.gen.migration -r MyApp.Repo
      $ mix restdis.gen.migration --repo MyApp.Repo --prefix restdis

  The generated file compiles and runs against a fresh database with no
  hand editing: it calls `Restdis.Migration.up/1` and `Restdis.Migration.down/1`
  at the version current when the file was generated.

  ## Command line options

    * `-r`, `--repo` - the repo to generate the migration for
    * `-p`, `--prefix` - the Postgres schema restdis's tables live in,
      defaults to #{inspect(Restdis.Migration.default_prefix())}
    * `--version` - the restdis migration version to install, defaults to
      the latest released version
    * `--no-compile` - does not compile applications before running
    * `--no-deps-check` - does not check dependencies before running
    * `--migrations-path` - the path to generate the migration in, defaults
      to `priv/repo/migrations`
  """

  @impl Mix.Task
  def run(args) do
    repos = parse_repo(args)

    {opts, _rest} = OptionParser.parse!(args, strict: @switches, aliases: @aliases)

    version = opts[:version] || Postgres.latest_version()
    prefix = opts[:prefix]

    Enum.map(repos, fn repo ->
      ensure_repo(repo, args)

      path = opts[:migrations_path] || Path.join(source_repo_priv(repo), "migrations")
      unless File.dir?(path), do: create_directory(path)

      base_name = "add_restdis.exs"
      fuzzy_path = Path.join(path, "*_#{base_name}")

      if Path.wildcard(fuzzy_path) != [] do
        Mix.raise(
          "migration can't be created, there is already a migration file named #{base_name}."
        )
      end

      file = Path.join(path, "#{timestamp()}_#{base_name}")

      assigns = [
        mod: Module.concat([repo, Migrations, AddRestdis]),
        version: version,
        prefix: prefix
      ]

      create_file(file, migration_template(assigns))

      file
    end)
  end

  defp timestamp do
    {{y, m, d}, {hh, mm, ss}} = :calendar.universal_time()
    "#{y}#{pad(m)}#{pad(d)}#{pad(hh)}#{pad(mm)}#{pad(ss)}"
  end

  defp pad(i) when i < 10, do: <<?0, ?0 + i>>
  defp pad(i), do: to_string(i)

  embed_template(:migration, """
  defmodule <%= inspect @mod %> do
    use Ecto.Migration

    def up do
      Restdis.Migration.up(<%= opts_string(@version, @prefix) %>)
    end

    def down do
      Restdis.Migration.down(<%= opts_string(@version, @prefix) %>)
    end
  end
  """)

  defp opts_string(version, nil), do: "version: #{version}"
  defp opts_string(version, prefix), do: "version: #{version}, prefix: #{inspect(prefix)}"
end
