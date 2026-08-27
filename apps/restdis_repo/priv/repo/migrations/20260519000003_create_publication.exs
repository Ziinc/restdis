defmodule RestdisRepo.Repo.Migrations.CreatePublication do
  use Ecto.Migration

  def up do
    # Requires Postgres user with REPLICATION privilege.
    # Skipped silently if the publication already exists.
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'restdis_pub') THEN
        CREATE PUBLICATION restdis_pub FOR ALL TABLES;
      END IF;
    END
    $$;
    """)
  end

  def down do
    execute("DROP PUBLICATION IF EXISTS restdis_pub")
  end
end
