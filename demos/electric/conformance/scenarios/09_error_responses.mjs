// The documented error contract: specific 400s for malformed requests, and
// 409+location for an unknown handle (must-refetch also covered end-to-end
// in 07_must_refetch.mjs). Raw fetch, since these are protocol-level checks
// the client library doesn't expose a way to trigger deliberately.

import { BASE_URL, API_KEY, assert } from "../lib/helpers.mjs";

async function shapeRequest(params) {
  const url = new URL(`${BASE_URL}/v1/shape`);
  for (const [key, value] of Object.entries(params)) url.searchParams.set(key, value);
  return fetch(url, { headers: { authorization: `Bearer ${API_KEY}` } });
}

export default async function run() {
  const missingTable = await shapeRequest({});
  assert(missingTable.status === 400, `missing table: expected 400, got ${missingTable.status}`);

  const unknownTable = await shapeRequest({ table: "no_such_table" });
  assert(unknownTable.status === 400, `unknown table: expected 400, got ${unknownTable.status}`);

  const missingPrimaryKey = await shapeRequest({ table: "conformance_items", columns: "name" });
  assert(
    missingPrimaryKey.status === 400,
    `columns without primary key: expected 400, got ${missingPrimaryKey.status}`
  );

  const unsupportedWhere = await shapeRequest({
    table: "conformance_items",
    where: "now() > created_at",
  });
  assert(
    unsupportedWhere.status === 400,
    `unsupported where clause: expected 400, got ${unsupportedWhere.status}`
  );

  const invalidOffset = await shapeRequest({ table: "conformance_items", offset: "not-an-offset" });
  assert(invalidOffset.status === 400, `invalid offset: expected 400, got ${invalidOffset.status}`);

  const unknownHandle = await shapeRequest({
    table: "conformance_items",
    handle: "does-not-exist",
    offset: "0_0",
  });
  assert(unknownHandle.status === 409, `unknown handle: expected 409, got ${unknownHandle.status}`);
  assert(unknownHandle.headers.get("location"), "unknown handle 409 had no location header");

  const deleteWithoutHandle = await fetch(`${BASE_URL}/v1/shape`, {
    method: "DELETE",
    headers: { authorization: `Bearer ${API_KEY}` },
  });
  assert(
    deleteWithoutHandle.status === 400,
    `DELETE without handle: expected 400, got ${deleteWithoutHandle.status}`
  );
}
