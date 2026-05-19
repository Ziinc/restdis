defmodule SupaCacherRepo.Repo.Migrations.CreateTenants do
  use Ecto.Migration

  def change do
    create table(:tenants, primary_key: false) do
      add :tenant_id, :text, primary_key: true
      add :default_ttl_s, :integer, null: false, default: 60
      add :persist_cap, :integer, null: false, default: 50_000
      add :pgrst_base_url, :text, null: false
      add :pgrst_api_key, :text, null: false
      add :replica_url, :text

      timestamps(type: :utc_datetime_usec)
    end
  end
end
