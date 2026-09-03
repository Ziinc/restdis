// Open mode's shared secret (ELECTRIC_PRD.md "Authentication": "an optional
// shared secret limits who may call at all"). A tenant configured with a
// secret should reject an open-mode shape request that omits it or gets it
// wrong, independent of the tenant's API key. The research behind this suite
// found no `secret`/gatekeeper code anywhere in restdis_electric or
// restdis_server — `secret` is accepted as an unrecognised query parameter
// and has no effect. Kept as `xfail` so this flips to a real failure, and
// gets noticed, the day the shared-secret check ships.

import { BASE_URL, API_KEY, assert } from "../lib/helpers.mjs";

export const xfail =
  "open mode's shared-secret check is not implemented (ELECTRIC_PRD.md Authentication section)";

export default async function run() {
  const url = new URL(`${BASE_URL}/v1/shape`);
  url.searchParams.set("table", "conformance_items");
  url.searchParams.set("secret", "wrong-secret");

  // conformance-tenant would need `shared_secret` configured for this to be
  // meaningful; assume the fixture will grow that column once the feature
  // exists. Until then, a wrong secret is silently accepted.
  const response = await fetch(url, { headers: { authorization: `Bearer ${API_KEY}` } });
  assert(
    response.status === 401 || response.status === 403,
    `a wrong shared secret should be rejected independent of the API key, got ${response.status}`
  );
}
