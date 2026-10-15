defmodule RestdisRepo.Repo.Migrations.AddPrimaryKeyToShapeDefinitions do
  use Ecto.Migration

  # A published table needs a replica identity before Postgres allows UPDATE or DELETE on it.
  def up do
    execute("""
    ALTER TABLE shape_definitions
      ADD CONSTRAINT shape_definitions_pkey
      PRIMARY KEY USING INDEX shape_definitions_tenant_id_name_index
    """)
  end

  def down do
    execute("ALTER TABLE shape_definitions DROP CONSTRAINT shape_definitions_pkey")
    create(unique_index(:shape_definitions, [:tenant_id, :name]))
  end
end
