// Gatekeeper mode (ELECTRIC_PRD.md "Authentication", Phase 7): a tenant
// names each shape server-side via `shape_definitions`; the client sends
// only the shape name and protocol parameters, and a client-supplied
// `table`/`where`/`columns` is rejected. Uses its own tenant/API key
// (conformance-gatekeeper-tenant) with a named shape "active_conformance_items"
// bound to `conformance_items` where `status = 'active'`.

import { BASE_URL, assert } from "../lib/helpers.mjs";

const GATEKEEPER_API_KEY = "sk_conformance_gatekeeper";

async function shapeRequest(params) {
  const url = new URL(`${BASE_URL}/v1/shape`);
  for (const [key, value] of Object.entries(params)) url.searchParams.set(key, value);
  return fetch(url, { headers: { authorization: `Bearer ${GATEKEEPER_API_KEY}` } });
}

export default async function run() {
  const named = await shapeRequest({ shape: "active_conformance_items" });
  assert(
    named.status === 200,
    `named-shape request under gatekeeper mode should resolve without a client-supplied table, got ${named.status}`
  );
  const body = await named.json();
  const rows = body.filter((m) => m.value);
  assert(
    rows.every((m) => m.value.status === "active"),
    `gatekeeper-resolved shape did not apply its server-side where clause: ${JSON.stringify(rows)}`
  );

  const missingShape = await shapeRequest({});
  assert(
    missingShape.status === 400,
    `gatekeeper mode without a 'shape' param should 400, got ${missingShape.status}`
  );

  const unknownShape = await shapeRequest({ shape: "does-not-exist" });
  assert(
    unknownShape.status === 400,
    `an unconfigured shape name should 400, got ${unknownShape.status}`
  );

  const smuggledTable = await shapeRequest({
    shape: "active_conformance_items",
    table: "conformance_items",
  });
  assert(
    smuggledTable.status === 400,
    `gatekeeper mode should reject a client-supplied table, got ${smuggledTable.status}`
  );

  const smuggledWhere = await shapeRequest({
    shape: "active_conformance_items",
    where: "1=1",
  });
  assert(
    smuggledWhere.status === 400,
    `gatekeeper mode should reject a client-supplied where, got ${smuggledWhere.status}`
  );
}
