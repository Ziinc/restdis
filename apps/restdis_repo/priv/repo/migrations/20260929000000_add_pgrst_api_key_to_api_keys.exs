defmodule RestdisRepo.Repo.Migrations.AddPgrstApiKeyToApiKeys do
  use Ecto.Migration

  def change do
    alter table(:api_keys) do
      add(:pgrst_api_key, :text)
    end
  end
end
