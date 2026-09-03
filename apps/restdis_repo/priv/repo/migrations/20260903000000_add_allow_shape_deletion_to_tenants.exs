defmodule RestdisRepo.Repo.Migrations.AddAllowShapeDeletionToTenants do
  use Ecto.Migration

  def change do
    alter table(:tenants) do
      add(:allow_shape_deletion, :boolean, null: false, default: false)
    end
  end
end
