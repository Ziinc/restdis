defmodule RestdisRepo.Repo.Migrations.AddMaxTtlToTenants do
  use Ecto.Migration

  def change do
    alter table(:tenants) do
      add(:max_ttl_s, :integer, null: false, default: 2_592_000)
    end
  end
end
