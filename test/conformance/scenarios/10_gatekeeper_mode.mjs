// Gatekeeper mode (ELECTRIC_PRD.md "Authentication"): a tenant names each
// shape definition server-side; the client sends only a shape name plus
// protocol parameters (`offset`, `handle`, `live`, `cursor`) and `table`,
// `where`, and `columns` from the client are rejected. This is documented as
// shipping alongside open mode, but the research behind this suite found no
// `gatekeeper`/`shape` (named-shape) handling anywhere in restdis_electric or
// restdis_server — only open mode (the client supplies the full shape
// definition) exists today. Kept as `xfail` so this flips to a real failure,
// and gets noticed, the day gatekeeper mode ships.

import { BASE_URL, API_KEY, assert } from "../lib/helpers.mjs";

export const xfail = "gatekeeper mode is not implemented (ELECTRIC_PRD.md Authentication section)";

export default async function run() {
  // A gatekeeper-configured tenant would resolve this named shape server
  // side; a client is not expected to (and per the PRD, must not) supply
  // `table` itself.
  const url = new URL(`${BASE_URL}/v1/shape`);
  url.searchParams.set("shape", "active_conformance_items");

  const response = await fetch(url, { headers: { authorization: `Bearer ${API_KEY}` } });
  assert(
    response.status === 200,
    `named-shape request under gatekeeper mode should resolve without a client-supplied table, got ${response.status}`
  );

  // Once gatekeeper mode exists, a gatekeeper-mode tenant must reject a
  // client that tries to supply `table`/`where`/`columns` directly.
  const smuggledTable = new URL(`${BASE_URL}/v1/shape`);
  smuggledTable.searchParams.set("shape", "active_conformance_items");
  smuggledTable.searchParams.set("table", "conformance_items");
  smuggledTable.searchParams.set("where", "1=1");

  const smuggledResponse = await fetch(smuggledTable, {
    headers: { authorization: `Bearer ${API_KEY}` },
  });
  assert(
    smuggledResponse.status === 400,
    `gatekeeper mode should reject a client-supplied table/where, got ${smuggledResponse.status}`
  );
}
