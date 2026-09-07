-- Seed fixture for the Supabase demo stack (demo/docker-compose.yml).
--
-- Runs once, at Postgres initdb time, via docker-entrypoint-initdb.d. Restdis
-- itself runs its own control-plane migrations (tenants, api_keys,
-- tenant_table_config, ...) on boot (rel/overlays/bin/migrate), so this file
-- only needs to create the demo domain table PostgREST exposes and, once
-- Restdis's migrations have created its control-plane tables, seed a tenant.
--
-- Because initdb scripts run before Restdis's first boot, the control-plane
-- inserts below are wrapped in a DO block that no-ops if the tables don't
-- exist yet; demo/tests/setup.ts re-applies them after Restdis is healthy to
-- guarantee the tenant exists regardless of startup ordering.

CREATE SCHEMA IF NOT EXISTS auth;

CREATE TABLE IF NOT EXISTS widgets (
  id integer PRIMARY KEY,
  name text NOT NULL
);

ALTER TABLE widgets REPLICA IDENTITY FULL;

INSERT INTO widgets (id, name) VALUES (1, 'first widget'), (2, 'second widget')
ON CONFLICT (id) DO NOTHING;

GRANT USAGE ON SCHEMA public TO postgres;
GRANT ALL ON widgets TO postgres;

DO $$
BEGIN
  IF to_regclass('public.tenants') IS NOT NULL THEN
    INSERT INTO tenants (
      tenant_id, default_ttl_s, persist_cap, pgrst_base_url, pgrst_api_key,
      direct_pg_url, allow_shape_deletion, auth_mode, inserted_at, updated_at
    ) VALUES (
      'demo-tenant', 60, 50000,
      'http://rest:3000', 'unused',
      'postgres://postgres:postgres@db:5432/postgres',
      true, 'open', now(), now()
    )
    ON CONFLICT (tenant_id) DO UPDATE SET pgrst_base_url = EXCLUDED.pgrst_base_url;

    INSERT INTO api_keys (api_key, tenant_id, status, inserted_at, updated_at)
    VALUES ('sk_demo', 'demo-tenant', 'active', now(), now())
    ON CONFLICT (api_key) DO UPDATE SET tenant_id = EXCLUDED.tenant_id;

    INSERT INTO tenant_table_config (
      tenant_id, schema, table_name, mode, pk_column, inserted_at, updated_at
    ) VALUES (
      'demo-tenant', 'public', 'widgets', 'replication', 'id', now(), now()
    )
    ON CONFLICT (tenant_id, schema, table_name) DO UPDATE SET mode = EXCLUDED.mode;
  END IF;
END $$;
