defmodule SupaCacherRepo.Repo.Migrations.CreateApiKeys do
  use Ecto.Migration

  def change do
    create table(:api_keys, primary_key: false) do
      add :api_key, :text, primary_key: true
      add :tenant_id, references(:tenants, column: :tenant_id, type: :text, on_delete: :delete_all), null: false
      add :status, :text, null: false, default: "active"

      timestamps(type: :utc_datetime_usec)
    end

    create index(:api_keys, [:tenant_id])
  end
end
