defmodule RestdisRepo.Repo.Migrations.AddShapeAuthToTenants do
  use Ecto.Migration

  def change do
    alter table(:tenants) do
      add(:shape_secret, :string)
      add(:auth_mode, :string, null: false, default: "gatekeeper")
      add(:max_log_operations, :integer)
    end
  end
end
