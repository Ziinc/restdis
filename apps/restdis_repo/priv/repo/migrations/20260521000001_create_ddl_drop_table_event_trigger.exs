defmodule RestdisRepo.Repo.Migrations.CreateDdlDropTableEventTrigger do
  use Ecto.Migration

  @moduledoc """
  Emits a logical-decoding message on `DROP TABLE` so `RestdisBuster.Worker`
  can flush the affected tenant's cache entries (see PRD.md, "DROP TABLE
  flushes all cache entries").

  The event trigger function fires on `ddl_command_end` for `sql_drop` and
  inspects `pg_event_trigger_dropped_objects()` for dropped tables. For each
  dropped table it calls `pg_logical_emit_message(true, 'restdis_ddl', ...)`
  with a JSON payload shaped as `{"op": "drop", "schema": ..., "table": ...}`,
  matching what `RestdisBuster.Worker.handle_ddl_message/1` expects.
  """

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION restdis_emit_ddl_drop_table()
    RETURNS event_trigger
    LANGUAGE plpgsql
    AS $$
    DECLARE
      obj record;
    BEGIN
      FOR obj IN SELECT * FROM pg_event_trigger_dropped_objects()
      LOOP
        IF obj.object_type = 'table' THEN
          PERFORM pg_logical_emit_message(
            true,
            'restdis_ddl',
            json_build_object(
              'op', 'drop',
              'schema', obj.schema_name,
              'table', obj.object_name
            )::text
          );
        END IF;
      END LOOP;
    END;
    $$;
    """)

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_event_trigger WHERE evtname = 'restdis_emit_ddl_drop_table'
      ) THEN
        CREATE EVENT TRIGGER restdis_emit_ddl_drop_table
          ON sql_drop
          EXECUTE FUNCTION restdis_emit_ddl_drop_table();
      END IF;
    END
    $$;
    """)
  end

  def down do
    execute("DROP EVENT TRIGGER IF EXISTS restdis_emit_ddl_drop_table")
    execute("DROP FUNCTION IF EXISTS restdis_emit_ddl_drop_table()")
  end
end
