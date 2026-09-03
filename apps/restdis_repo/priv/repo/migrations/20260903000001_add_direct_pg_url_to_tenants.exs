defmodule RestdisRepo.Repo.Migrations.AddDirectPgUrlToTenants do
  use Ecto.Migration

  def change do
    alter table(:tenants) do
      add(:direct_pg_url, :string)
    end
  end
end
