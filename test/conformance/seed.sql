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

-- `auth_mode` defaults to 'gatekeeper' (ELECTRIC_PRD.md Phase 7), which rejects a client-supplied
-- `table` parameter. This fixture's client sends `table` directly, so it needs 'open' explicitly.
INSERT INTO tenants (
  tenant_id, default_ttl_s, persist_cap, pgrst_base_url, pgrst_api_key,
  direct_pg_url, allow_shape_deletion, auth_mode, inserted_at, updated_at
) VALUES (
  'conformance-tenant', 60, 50000,
  'http://unused.invalid', 'unused',
  :'direct_pg_url',
  true, 'open', now(), now()
)
ON CONFLICT (tenant_id) DO UPDATE SET direct_pg_url = EXCLUDED.direct_pg_url, auth_mode = EXCLUDED.auth_mode;

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

-- A richer table for the rest of the conformance suite: update/delete
-- operation semantics, `where`-clause enter/exit transitions, `columns`
-- projection, and `replica=full` old_value. `status` drives the where-clause
-- shape ('status = 'active'); `price` is the column exercised by the
-- replica=full old_value check.
DROP TABLE IF EXISTS conformance_items;

CREATE TABLE conformance_items (
  id integer PRIMARY KEY,
  name text NOT NULL,
  status text NOT NULL,
  price integer NOT NULL
);

ALTER TABLE conformance_items REPLICA IDENTITY FULL;

INSERT INTO conformance_items (id, name, status, price) VALUES
  (1, 'first item', 'active', 100),
  (2, 'second item', 'inactive', 200);

INSERT INTO tenant_table_config (
  tenant_id, schema, table_name, mode, pk_column, inserted_at, updated_at
) VALUES (
  'conformance-tenant', 'public', 'conformance_items', 'replication', 'id', now(), now()
)
ON CONFLICT (tenant_id, schema, table_name) DO UPDATE SET mode = EXCLUDED.mode;

-- A second table, read only through a subquery, for the `field IN
-- (subquery) AND ...` conformance scenario (ELECTRIC_PRD.md Phase 6 item 1,
-- extended for AND/OR). RestdisElectric.SubqueryTracker needs its own
-- tenant_table_config row to receive WAL changes at all, exactly like any
-- other tracked table.
DROP TABLE IF EXISTS conformance_subquery_source;

CREATE TABLE conformance_subquery_source (
  id integer PRIMARY KEY,
  enabled boolean NOT NULL
);

ALTER TABLE conformance_subquery_source REPLICA IDENTITY FULL;

INSERT INTO conformance_subquery_source (id, enabled) VALUES
  (90, true),
  (91, false);

INSERT INTO tenant_table_config (
  tenant_id, schema, table_name, mode, pk_column, inserted_at, updated_at
) VALUES (
  'conformance-tenant', 'public', 'conformance_subquery_source', 'replication', 'id', now(), now()
)
ON CONFLICT (tenant_id, schema, table_name) DO UPDATE SET mode = EXCLUDED.mode;

-- A gatekeeper-mode tenant (ELECTRIC_PRD.md Phase 7): the client sends only
-- a `shape` name and protocol parameters; `table`/`where`/`columns` are
-- resolved server-side from `shape_definitions` and rejected if the client
-- supplies them itself.
INSERT INTO tenants (
  tenant_id, default_ttl_s, persist_cap, pgrst_base_url, pgrst_api_key,
  direct_pg_url, allow_shape_deletion, auth_mode, inserted_at, updated_at
) VALUES (
  'conformance-gatekeeper-tenant', 60, 50000,
  'http://unused.invalid', 'unused',
  :'direct_pg_url',
  false, 'gatekeeper', now(), now()
)
ON CONFLICT (tenant_id) DO UPDATE SET direct_pg_url = EXCLUDED.direct_pg_url, auth_mode = EXCLUDED.auth_mode;

INSERT INTO api_keys (api_key, tenant_id, status, inserted_at, updated_at)
VALUES ('sk_conformance_gatekeeper', 'conformance-gatekeeper-tenant', 'active', now(), now())
ON CONFLICT (api_key) DO UPDATE SET tenant_id = EXCLUDED.tenant_id;

INSERT INTO tenant_table_config (
  tenant_id, schema, table_name, mode, pk_column, inserted_at, updated_at
) VALUES (
  'conformance-gatekeeper-tenant', 'public', 'conformance_items', 'replication', 'id', now(), now()
)
ON CONFLICT (tenant_id, schema, table_name) DO UPDATE SET mode = EXCLUDED.mode;

INSERT INTO shape_definitions (
  tenant_id, name, "table", "where", replica, inserted_at, updated_at
) VALUES (
  'conformance-gatekeeper-tenant', 'active_conformance_items', 'conformance_items',
  'status = ''active''', 'default', now(), now()
)
ON CONFLICT (tenant_id, name) DO UPDATE SET "table" = EXCLUDED."table", "where" = EXCLUDED."where";

-- An open-mode tenant with a shape secret configured (ELECTRIC_PRD.md Phase
-- 7): a request must supply `secret` matching this value, independent of
-- the API key that already identifies the tenant.
INSERT INTO tenants (
  tenant_id, default_ttl_s, persist_cap, pgrst_base_url, pgrst_api_key,
  direct_pg_url, allow_shape_deletion, auth_mode, shape_secret, inserted_at, updated_at
) VALUES (
  'conformance-secret-tenant', 60, 50000,
  'http://unused.invalid', 'unused',
  :'direct_pg_url',
  false, 'open', 'conformance-shape-secret', now(), now()
)
ON CONFLICT (tenant_id) DO UPDATE SET
  direct_pg_url = EXCLUDED.direct_pg_url,
  auth_mode = EXCLUDED.auth_mode,
  shape_secret = EXCLUDED.shape_secret;

INSERT INTO api_keys (api_key, tenant_id, status, inserted_at, updated_at)
VALUES ('sk_conformance_secret', 'conformance-secret-tenant', 'active', now(), now())
ON CONFLICT (api_key) DO UPDATE SET tenant_id = EXCLUDED.tenant_id;

INSERT INTO tenant_table_config (
  tenant_id, schema, table_name, mode, pk_column, inserted_at, updated_at
) VALUES (
  'conformance-secret-tenant', 'public', 'conformance_items', 'replication', 'id', now(), now()
)
ON CONFLICT (tenant_id, schema, table_name) DO UPDATE SET mode = EXCLUDED.mode;
