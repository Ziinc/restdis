// Open mode's shared secret (ELECTRIC_PRD.md "Authentication", Phase 7): a
// tenant with `shape_secret` set must reject a request whose `secret` query
// parameter is missing or wrong, independent of the API key that already
// identifies the tenant. Uses its own tenant/API key
// (conformance-secret-tenant) configured with shape_secret =
// 'conformance-shape-secret'.

import { BASE_URL, assert } from "../lib/helpers.mjs";

const SECRET_API_KEY = "sk_conformance_secret";
const CORRECT_SECRET = "conformance-shape-secret";

async function shapeRequest(params) {
  const url = new URL(`${BASE_URL}/v1/shape`);
  url.searchParams.set("table", "conformance_items");
  for (const [key, value] of Object.entries(params)) url.searchParams.set(key, value);
  return fetch(url, { headers: { authorization: `Bearer ${SECRET_API_KEY}` } });
}

export default async function run() {
  const missingSecret = await shapeRequest({});
  assert(
    missingSecret.status === 401,
    `a missing shared secret should be rejected, got ${missingSecret.status}`
  );

  const wrongSecret = await shapeRequest({ secret: "wrong-secret" });
  assert(
    wrongSecret.status === 401,
    `a wrong shared secret should be rejected, got ${wrongSecret.status}`
  );

  const correctSecret = await shapeRequest({ secret: CORRECT_SECRET });
  assert(
    correctSecret.status === 200,
    `the correct shared secret should be accepted, got ${correctSecret.status}`
  );
}
