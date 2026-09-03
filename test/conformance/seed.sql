-- Minimal fixture for the Electric conformance check (Phase 6 item 7).
--
-- Creates one table the shape subscribes to, one tenant configured to read
-- its snapshot directly from Postgres (RestdisElectric.Snapshotter.DirectPostgres,
-- selected by RESTDIS_SNAPSHOT_READER=direct_postgres — see config/dev.exs), and
-- one API key. Run against the same database the `app` container uses.

DROP TABLE IF EXISTS conformance_widgets;

CREATE TABLE conformance_widgets (
  id integer PRIMARY KEY,
  name text NOT NULL
);

ALTER TABLE conformance_widgets REPLICA IDENTITY FULL;

INSERT INTO conformance_widgets (id, name) VALUES (1, 'first widget');

-- Pass -v direct_pg_url='postgres://...' on the psql command line to override;
-- defaults to the hostname the `app` container resolves inside docker compose.
\set direct_pg_url `test -n "$DIRECT_PG_URL_OVERRIDE" && echo "$DIRECT_PG_URL_OVERRIDE" || echo 'postgres://postgres:postgres@db:5432/restdis_dev'`

INSERT INTO tenants (
  tenant_id, default_ttl_s, persist_cap, pgrst_base_url, pgrst_api_key,
  direct_pg_url, allow_shape_deletion, inserted_at, updated_at
) VALUES (
  'conformance-tenant', 60, 50000,
  'http://unused.invalid', 'unused',
  :'direct_pg_url',
  true, now(), now()
)
ON CONFLICT (tenant_id) DO UPDATE SET direct_pg_url = EXCLUDED.direct_pg_url;

INSERT INTO api_keys (api_key, tenant_id, status, inserted_at, updated_at)
VALUES ('sk_conformance', 'conformance-tenant', 'active', now(), now())
ON CONFLICT (api_key) DO UPDATE SET tenant_id = EXCLUDED.tenant_id;

-- RestdisBuster.Worker only dispatches a WAL change to a shape (`ingest_shape_change`)
-- when `tenant_table_config` has a row for the table; without this, the snapshot
-- would work but a live write would never reach the shape's log.
INSERT INTO tenant_table_config (
  tenant_id, schema, table_name, mode, pk_column, inserted_at, updated_at
) VALUES (
  'conformance-tenant', 'public', 'conformance_widgets', 'replication', 'id', now(), now()
)
ON CONFLICT (tenant_id, schema, table_name) DO UPDATE SET mode = EXCLUDED.mode;
