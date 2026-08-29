defmodule Restdis.Migrations.Postgres.V01 do
  @moduledoc """
  Version 1 of the library's Postgres schema.

  Creates `tenants`, `tenant_table_config` and `wal_checkpoint`, collapsing
  the four table migrations the umbrella application used to own (minus
  `api_keys`, which stays an application concern).
  """

  import Ecto.Migration

  @doc false
  def up(opts \\ []) do
    prefix = Keyword.fetch!(opts, :prefix)

    create table(:tenants, primary_key: false, prefix: prefix) do
      add(:tenant_id, :text, primary_key: true)
      add(:default_ttl_s, :integer, null: false, default: 60)
      add(:persist_cap, :integer, null: false, default: 50_000)
      add(:pgrst_base_url, :text, null: false)
      add(:pgrst_api_key, :text, null: false)
      add(:replica_url, :text)

      timestamps(type: :utc_datetime_usec)
    end

    create table(:tenant_table_config, primary_key: false, prefix: prefix) do
      add(:tenant_id, :text, null: false, primary_key: true)
      add(:schema, :text, null: false, default: "public", primary_key: true)
      add(:table_name, :text, null: false, primary_key: true)
      add(:mode, :text, null: false, default: "ttl")
      add(:pk_column, :text, null: false, default: "id")
      add(:filter, :text)

      timestamps()
    end

    create(
      constraint(:tenant_table_config, :valid_mode,
        check: "mode IN ('ttl', 'replication')",
        prefix: prefix
      )
    )

    create table(:wal_checkpoint, primary_key: false, prefix: prefix) do
      add(:slot_name, :string, primary_key: true)
      add(:lsn, :bigint, null: false, default: 0)

      timestamps()
    end

    :ok
  end

  @doc false
  def down(opts \\ []) do
    prefix = Keyword.fetch!(opts, :prefix)

    drop(table(:wal_checkpoint, prefix: prefix))
    drop(table(:tenant_table_config, prefix: prefix))
    drop(table(:tenants, prefix: prefix))

    :ok
  end
end
