defmodule RestdisRepo.Repo.Migrations.AddShapeLimitsToTenants do
  use Ecto.Migration

  def change do
    alter table(:tenants) do
      add(:max_shapes, :integer)
      add(:max_log_bytes, :integer)
      add(:max_waiting_clients, :integer)
    end
  end
end
