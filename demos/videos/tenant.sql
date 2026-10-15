-- Demo tenant. Run after Restdis has booted and migrated:
--   docker compose exec -T db psql -U postgres -f - < tenant.sql

INSERT INTO tenants (
  tenant_id, default_ttl_s, persist_cap, pgrst_base_url, pgrst_api_key,
  direct_pg_url, allow_shape_deletion, auth_mode, inserted_at, updated_at
) VALUES (
  'demo-tenant', 300, 50000,
  'http://rest:3000', 'unused',
  'postgres://postgres:postgres@db:5432/postgres',
  true, 'open', now(), now()
)
ON CONFLICT (tenant_id) DO NOTHING;

INSERT INTO api_keys (api_key, tenant_id, status, inserted_at, updated_at)
VALUES ('sk_demo', 'demo-tenant', 'active', now(), now())
ON CONFLICT (api_key) DO NOTHING;

-- products: TTL mode. A write evicts the cached reads it affects.
-- todos: replication mode. A write is pushed to live Electric shapes.
INSERT INTO tenant_table_config (
  tenant_id, schema, table_name, mode, pk_column, inserted_at, updated_at
) VALUES
  ('demo-tenant', 'public', 'products', 'ttl', 'id', now(), now()),
  ('demo-tenant', 'public', 'todos', 'replication', 'id', now(), now())
ON CONFLICT (tenant_id, schema, table_name) DO NOTHING;
