defmodule RestdisRepo.Migrations.CreateWalCheckpoint do
  use Ecto.Migration

  def change do
    create table(:wal_checkpoint, primary_key: false) do
      add(:slot_name, :string, primary_key: true)
      add(:lsn, :bigint, null: false, default: 0)
      timestamps()
    end
  end
end
