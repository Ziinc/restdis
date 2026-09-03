defmodule RestdisRepo.Repo.Migrations.CreateShapeDefinitions do
  use Ecto.Migration

  def change do
    create table(:shape_definitions, primary_key: false) do
      add(:tenant_id, :string, null: false)
      add(:name, :string, null: false)
      add(:table, :string, null: false)
      add(:where, :text)
      add(:columns, {:array, :string})
      add(:replica, :string, default: "default")

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:shape_definitions, [:tenant_id, :name]))
  end
end
