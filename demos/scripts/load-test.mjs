#!/usr/bin/env node
// Load-test demonstration for the screen recording: seeds many synthetic
// tenants sharing the demo's `widgets` origin table, then hammers Restdis's
// PGRST cache across all of them at once, at high concurrency, for a fixed
// duration. The point is to make the Grafana dashboard's panels move under
// real concurrent multi-tenant load on camera - this is not a rigorous
// benchmark, and result quality depends entirely on the host machine.
//
// No npm dependencies: shells out to `psql` (already required by
// demos/scripts/demo.sh) for seeding and uses the built-in `fetch` for load.
//
// Usage: node load-test.mjs
// Env:   LOAD_TENANTS (default 10), LOAD_CONCURRENCY (default 50),
//        LOAD_DURATION_S (default 15), RESTDIS_URL, DEMO_DIRECT_PG_URL

import { execFileSync } from "node:child_process";

const RESTDIS_URL = process.env.RESTDIS_URL ?? "http://localhost:4041";
const DIRECT_PG_URL =
  process.env.DEMO_DIRECT_PG_URL ?? "postgres://postgres:postgres@localhost:5433/postgres";
const TENANT_COUNT = Number(process.env.LOAD_TENANTS ?? 10);
const CONCURRENCY = Number(process.env.LOAD_CONCURRENCY ?? 50);
const DURATION_S = Number(process.env.LOAD_DURATION_S ?? 15);

const tenants = Array.from({ length: TENANT_COUNT }, (_, i) => ({
  tenantId: `load-tenant-${i}`,
  apiKey: `sk_load_${i}`,
}));

function seedTenants() {
  const tenantValues = tenants
    .map(
      (t) =>
        `('${t.tenantId}', 60, 50000, 'http://rest:3000', 'unused', 'postgres://postgres:postgres@db:5432/postgres', true, 'open', now(), now())`
    )
    .join(",\n");

  const perTenant = tenants
    .map(
      (t) => `
INSERT INTO api_keys (api_key, tenant_id, status, inserted_at, updated_at)
VALUES ('${t.apiKey}', '${t.tenantId}', 'active', now(), now())
ON CONFLICT (api_key) DO UPDATE SET tenant_id = EXCLUDED.tenant_id;

INSERT INTO tenant_table_config (
  tenant_id, schema, table_name, mode, pk_column, inserted_at, updated_at
) VALUES ('${t.tenantId}', 'public', 'widgets', 'ttl', 'id', now(), now())
ON CONFLICT (tenant_id, schema, table_name) DO UPDATE SET mode = EXCLUDED.mode;`
    )
    .join("\n");

  const sql = `
INSERT INTO tenants (
  tenant_id, default_ttl_s, persist_cap, pgrst_base_url, pgrst_api_key,
  direct_pg_url, allow_shape_deletion, auth_mode, inserted_at, updated_at
) VALUES ${tenantValues}
ON CONFLICT (tenant_id) DO UPDATE SET pgrst_base_url = EXCLUDED.pgrst_base_url;
${perTenant}
`;

  execFileSync("psql", [DIRECT_PG_URL, "-v", "ON_ERROR_STOP=1", "-c", sql], { stdio: "inherit" });
}

const PATH = encodeURIComponent("widgets?select=id,name&order=id");

async function fireOne(tenant) {
  const res = await fetch(`${RESTDIS_URL}/pgrst/query?path=${PATH}`, {
    headers: { authorization: `Bearer ${tenant.apiKey}` },
  });
  await res.arrayBuffer();
  return res.status;
}

async function main() {
  console.log(`Seeding ${TENANT_COUNT} tenants sharing the widgets table...`);
  seedTenants();

  console.log(
    `\nFiring requests across ${TENANT_COUNT} tenants at concurrency ${CONCURRENCY} for ${DURATION_S}s.`
  );
  console.log("Watch the Grafana dashboard: WAL/persist panels stay flat (all cache hits),");
  console.log("proving Restdis, not PostgREST, is absorbing this traffic.\n");

  const deadline = Date.now() + DURATION_S * 1000;
  let completed = 0;
  let errors = 0;
  let lastReportAt = Date.now();
  let lastCompleted = 0;

  const workers = Array.from({ length: CONCURRENCY }, async (_, workerIndex) => {
    let tenantIndex = workerIndex % TENANT_COUNT;
    while (Date.now() < deadline) {
      try {
        const status = await fireOne(tenants[tenantIndex]);
        if (status >= 400) errors++;
      } catch {
        errors++;
      }
      completed++;
      tenantIndex = (tenantIndex + 1) % TENANT_COUNT;
    }
  });

  const reporter = setInterval(() => {
    const now = Date.now();
    const rate = Math.round(((completed - lastCompleted) * 1000) / (now - lastReportAt));
    console.log(`  ${completed} requests so far (~${rate} req/s), ${errors} errors`);
    lastCompleted = completed;
    lastReportAt = now;
  }, 1000);

  await Promise.all(workers);
  clearInterval(reporter);

  const totalRate = Math.round((completed * 1000) / (DURATION_S * 1000));
  console.log(
    `\nDone: ${completed} requests across ${TENANT_COUNT} tenants in ${DURATION_S}s (~${totalRate} req/s average), ${errors} errors.`
  );
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
