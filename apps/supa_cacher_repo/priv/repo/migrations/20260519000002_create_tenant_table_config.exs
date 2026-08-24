defmodule SupaCacherRepo.Repo.Migrations.CreateTenantTableConfig do
  use Ecto.Migration

  def change do
    create table(:tenant_table_config, primary_key: false) do
      add(:tenant_id, :text, null: false)
      add(:schema, :text, null: false, default: "public")
      add(:table_name, :text, null: false)
      add(:mode, :text, null: false, default: "ttl")
      add(:pk_column, :text, null: false, default: "id")
      add(:filter, :text)

      timestamps()
    end

    create(constraint(:tenant_table_config, :valid_mode, check: "mode IN ('ttl', 'replication')"))
    create(primary_key(:tenant_table_config, [:tenant_id, :schema, :table_name]))
  end
end
