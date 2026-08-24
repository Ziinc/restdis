defmodule SupaCacherRepo.Repo.Migrations.CreateTenantTableConfig do
  use Ecto.Migration

  def change do
    create table(:tenant_table_config, primary_key: false) do
      add(:tenant_id, :text, null: false, primary_key: true)
      add(:schema, :text, null: false, default: "public", primary_key: true)
      add(:table_name, :text, null: false, primary_key: true)
      add(:mode, :text, null: false, default: "ttl")
      add(:pk_column, :text, null: false, default: "id")
      add(:filter, :text)

      timestamps()
    end

    create(constraint(:tenant_table_config, :valid_mode, check: "mode IN ('ttl', 'replication')"))
  end
end
