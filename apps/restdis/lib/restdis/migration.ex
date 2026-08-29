defmodule Restdis.Migration do
  @moduledoc """
  Oban-style migration surface for the library's control-plane tables.

  A host application never runs the library's migration modules directly;
  it writes one migration, once, that delegates to this module from inside
  an `Ecto.Migration`:

      defmodule MyApp.Repo.Migrations.AddRestdis do
        use Ecto.Migration

        def up, do: Restdis.Migration.up(version: 1)
        def down, do: Restdis.Migration.down(version: 1)
      end

  Because this runs inside the host's own migration, there is no `:repo`
  option: `Ecto.Migration` already knows which repo and connection it is
  running against, and every DDL statement issued here rides the host's
  migration transaction.
  """

  import Ecto.Migration, only: [execute: 1]

  alias Restdis.Migrations.Postgres

  @default_prefix "restdis"

  @doc "The schema prefix used when none is given."
  def default_prefix, do: @default_prefix

  @doc """
  Applies the library's migrations up to `:version` (defaulting to the
  latest released version).

  Options:

    * `:version` - the target version, defaults to the latest released
      version.
    * `:prefix` - the Postgres schema the tables live in, defaults to
      `#{inspect(@default_prefix)}`.
    * `:create_schema` - whether to `CREATE SCHEMA IF NOT EXISTS` for
      `:prefix` before applying migrations, defaults to `true`.

  Calling `up/1` twice at the same version is a no-op the second time.
  """
  def up(opts \\ []), do: Postgres.up(opts)

  @doc """
  Reverses the library's migrations down to `:version` (exclusive),
  defaulting to one below the latest released version, i.e. reversing only
  the most recently applied version.

  Accepts the same `:version` and `:prefix` options as `up/1`.
  """
  def down(opts \\ []), do: Postgres.down(opts)

  @doc """
  Returns the schema version recorded for `:prefix` (defaulting to
  `#{inspect(@default_prefix)}`), or `0` if the schema has never been
  migrated.
  """
  def migrated_version(opts \\ []), do: Postgres.migrated_version(opts)

  @doc """
  Creates the WAL publication used by `Restdis.Wal`.

  This is a separate, privileged helper rather than a versioned migration
  step: `CREATE PUBLICATION` requires a replication-privileged role, and
  `FOR ALL TABLES` vs. an explicit table list is the consumer's policy
  decision, not something a schema migration should decide.

  Options:

    * `:name` - the publication name, defaults to `"restdis_pub"`.
    * `:for_all_tables` - whether to scope the publication to every table
      in the database, defaults to `true`.
    * `:tables` - an explicit list of tables to publish, used instead of
      `:for_all_tables` when given.
  """
  def create_publication(opts \\ []) do
    name = Keyword.get(opts, :name, "restdis_pub")
    tables = Keyword.get(opts, :tables)

    target =
      case tables do
        nil -> "FOR ALL TABLES"
        [] -> "FOR ALL TABLES"
        tables -> "FOR TABLE " <> Enum.join(tables, ", ")
      end

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = #{quote_literal(name)}) THEN
        CREATE PUBLICATION #{quote_ident(name)} #{target};
      END IF;
    END
    $$;
    """)

    :ok
  end

  @doc "Drops the WAL publication created by `create_publication/1`."
  def drop_publication(opts \\ []) do
    name = Keyword.get(opts, :name, "restdis_pub")
    execute("DROP PUBLICATION IF EXISTS #{quote_ident(name)}")
    :ok
  end

  defp quote_ident(ident), do: ~s("#{String.replace(ident, "\"", "\"\"")}")
  defp quote_literal(value), do: "'#{String.replace(value, "'", "''")}'"
end
