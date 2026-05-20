defmodule SupaCacherRepo.Repo.Migrations.CreatePublication do
  use Ecto.Migration

  def up do
    # Requires Postgres user with REPLICATION privilege.
    # Skipped silently if the publication already exists.
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supacacher_pub') THEN
        CREATE PUBLICATION supacacher_pub FOR ALL TABLES;
      END IF;
    END
    $$;
    """)
  end

  def down do
    execute("DROP PUBLICATION IF EXISTS supacacher_pub")
  end
end
