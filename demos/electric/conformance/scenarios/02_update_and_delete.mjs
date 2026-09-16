// Insert/update/delete operation semantics on an unfiltered shape.
// RestdisElectric.WAL.ingest/1 derives the *logged* operation from whether
// the pre- and post-image match the shape's filter; with no `where` clause
// every row always matches, so this should mirror the raw Postgres op.

import {
  newStream,
  collect,
  waitUntil,
  assert,
  pgQuery,
  inserts,
  updates,
  deletes,
} from "../lib/helpers.mjs";

export default async function run() {
  const stream = newStream({ table: "conformance_items", where: "id >= 10" });
  const { seen, unsubscribe } = collect(stream);

  await pgQuery(
    "INSERT INTO conformance_items (id, name, status, price) VALUES ($1, $2, $3, $4)",
    [10, "widget-10", "active", 500]
  );
  const inserted = await waitUntil(() => inserts(seen).find((m) => m.value?.id === 10));
  assert(inserted.value.name === "widget-10", `unexpected insert: ${JSON.stringify(inserted)}`);

  await pgQuery("UPDATE conformance_items SET name = $1 WHERE id = 10", ["widget-10-renamed"]);
  const updated = await waitUntil(() => updates(seen).find((m) => m.value?.id === 10));
  assert(
    updated.value.name === "widget-10-renamed",
    `update did not carry the new value: ${JSON.stringify(updated)}`
  );

  await pgQuery("DELETE FROM conformance_items WHERE id = 10");
  const deleted = await waitUntil(() => deletes(seen).find((m) => m.value?.id === 10));
  assert(deleted.headers.operation === "delete", `expected a delete op: ${JSON.stringify(deleted)}`);

  unsubscribe();
}
