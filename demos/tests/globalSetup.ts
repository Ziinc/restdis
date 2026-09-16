import pg from "pg";

const DIRECT_PG_URL =
  process.env.DEMO_DIRECT_PG_URL ?? "postgres://postgres:postgres@localhost:5433/postgres";

// Restdis's control-plane tables (tenants, api_keys, tenant_table_config) are
// created by its own release migrations on boot, which may finish after
// demos/seed.sql's initdb-time insert attempt no-ops. Re-applying the same
// upserts here, once Restdis is confirmed healthy, guarantees the demo
// tenant exists regardless of startup ordering between the `db` and
// `restdis` containers.
export default async function setup() {
  await waitForHttp(`${process.env.RESTDIS_URL ?? "http://localhost:4041"}/health`);

  const client = new pg.Client({ connectionString: DIRECT_PG_URL });
  await client.connect();
  try {
    await client.query(
      `INSERT INTO tenants (
         tenant_id, default_ttl_s, persist_cap, pgrst_base_url, pgrst_api_key,
         direct_pg_url, allow_shape_deletion, auth_mode, inserted_at, updated_at
       ) VALUES (
         'demo-tenant', 60, 50000, 'http://rest:3000', 'unused',
         'postgres://postgres:postgres@db:5432/postgres', true, 'open', now(), now()
       )
       ON CONFLICT (tenant_id) DO UPDATE SET pgrst_base_url = EXCLUDED.pgrst_base_url`
    );
    await client.query(
      `INSERT INTO api_keys (api_key, tenant_id, status, inserted_at, updated_at)
       VALUES ('sk_demo', 'demo-tenant', 'active', now(), now())
       ON CONFLICT (api_key) DO UPDATE SET tenant_id = EXCLUDED.tenant_id`
    );
    await client.query(
      `INSERT INTO tenant_table_config (
         tenant_id, schema, table_name, mode, pk_column, inserted_at, updated_at
       ) VALUES ('demo-tenant', 'public', 'widgets', 'ttl', 'id', now(), now())
       ON CONFLICT (tenant_id, schema, table_name) DO UPDATE SET mode = EXCLUDED.mode`
    );
  } finally {
    await client.end();
  }
}

async function waitForHttp(url: string, timeoutMs = 60_000) {
  const deadline = Date.now() + timeoutMs;
  let lastError: unknown;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(url);
      if (res.ok) return;
    } catch (err) {
      lastError = err;
    }
    await new Promise((resolve) => setTimeout(resolve, 1_000));
  }
  throw new Error(`${url} never became healthy: ${String(lastError)}`);
}
