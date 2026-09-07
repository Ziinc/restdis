defmodule Restdis.Migrations.Postgres do
  @moduledoc """
  Stepwise runner for the library's Postgres migrations.

  Reads the version recorded in a table comment on `tenants` and applies
  `V01..VN` in order for `up/1`, reversing the order for `down/1`.
  """

  import Ecto.Migration

  alias Restdis.Migrations.SqlQuoting

  @versions %{
    1 => Restdis.Migrations.Postgres.V01
  }

  @latest_version @versions |> Map.keys() |> Enum.max()

  @comment_prefix "restdis:version:"

  @doc false
  @spec latest_version() :: pos_integer()
  def latest_version, do: @latest_version

  @doc """
  Applies every migration module between the recorded version (exclusive)
  and `version` (inclusive), in ascending order.
  """
  @spec up(keyword()) :: :ok
  def up(opts \\ []) do
    prefix = fetch_prefix(opts)
    target = Keyword.get(opts, :version, @latest_version)
    create_schema = Keyword.get(opts, :create_schema, true)

    if create_schema do
      execute("CREATE SCHEMA IF NOT EXISTS #{SqlQuoting.quote_ident(prefix)}")
      flush()
    end

    current = migrated_version(opts)

    @versions
    |> Enum.filter(fn {version, _module} -> version > current and version <= target end)
    |> Enum.sort_by(fn {version, _module} -> version end)
    |> Enum.each(fn {version, module} ->
      module.up(prefix: prefix)
      record_version(prefix, version)
      flush()
    end)

    :ok
  end

  @doc """
  Reverses every migration module between the recorded version and
  `version` (exclusive), in descending order.
  """
  @spec down(keyword()) :: :ok
  def down(opts \\ []) do
    prefix = fetch_prefix(opts)

    # `:version` names the version undone: `down(version: 1)` reverses `up(version: 1)`, landing on version 0.
    target = Keyword.get(opts, :version, @latest_version) - 1

    current = migrated_version(opts)

    @versions
    |> Enum.filter(fn {version, _module} -> version <= current and version > target end)
    |> Enum.sort_by(fn {version, _module} -> version end, :desc)
    |> Enum.each(fn {version, module} ->
      module.down(prefix: prefix)

      if version - 1 > 0 do
        record_version(prefix, version - 1)
      end

      flush()
    end)

    :ok
  end

  @doc """
  Reads the version recorded in the table comment on `tenants`, or `0` if
  `tenants` does not exist yet or carries no recognised comment.
  """
  @spec migrated_version(keyword()) :: non_neg_integer()
  def migrated_version(opts \\ []) do
    prefix = fetch_prefix(opts)
    repo = fetch_repo(opts)

    query = """
    SELECT obj_description(c.oid, 'pg_class')
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = $1 AND c.relname = 'tenants'
    """

    case repo.query(query, [prefix]) do
      {:ok, %{rows: [[comment]]}} when is_binary(comment) -> parse_version(comment)
      _ -> 0
    end
  end

  defp record_version(prefix, version) do
    comment = @comment_prefix <> Integer.to_string(version)

    execute(
      "COMMENT ON TABLE #{SqlQuoting.quote_ident(prefix)}.tenants IS #{SqlQuoting.quote_literal(comment)}"
    )
  end

  defp parse_version(@comment_prefix <> rest) do
    case Integer.parse(rest) do
      {version, ""} -> version
      _ -> 0
    end
  end

  defp parse_version(_), do: 0

  defp fetch_prefix(opts), do: Keyword.get(opts, :prefix, Restdis.Migration.default_prefix())

  # Inside a running migration the repo is implicit; otherwise an explicit `:repo` option must be given.
  defp fetch_repo(opts) do
    case Keyword.fetch(opts, :repo) do
      {:ok, repo} ->
        repo

      :error ->
        if running_migration?() do
          repo()
        else
          raise ArgumentError,
                "Restdis.Migrations.Postgres.migrated_version/1 needs a :repo option " <>
                  "when called outside of a running Ecto.Migration"
        end
    end
  end

  defp running_migration?, do: Process.get(:ecto_migration) != nil
end
