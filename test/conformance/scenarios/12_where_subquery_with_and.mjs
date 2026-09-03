// RestdisElectric.Eval's moduledoc: `field IN (subquery)` parses and
// structurally validates on its own, but "a subquery combined with AND/OR is
// still rejected, because that would require this module to also decide the
// surrounding clause against a partially-invalidated row, which it does not
// yet do." A fully documented Postgres `where` subset should let a client
// combine a subquery with a plain predicate. Kept as `xfail` so this flips
// to a real failure, and gets noticed, the day combined subqueries ship.

import { newStream, collect, waitUntil, assert, pgQuery, inserts } from "../lib/helpers.mjs";

export const xfail =
  "a subquery combined with AND/OR in `where` is rejected (RestdisElectric.Eval moduledoc)";

export default async function run() {
  const stream = newStream({
    table: "conformance_items",
    where: "status = 'active' AND id IN (SELECT id FROM conformance_items WHERE price > 0)",
  });
  const { seen, unsubscribe } = collect(stream);

  await pgQuery(
    "INSERT INTO conformance_items (id, name, status, price) VALUES ($1, $2, $3, $4)",
    [90, "combined-subquery-row", "active", 5]
  );

  const inserted = await waitUntil(() => inserts(seen).find((m) => m.value?.id === 90));
  assert(
    inserted.value.name === "combined-subquery-row",
    `a row matching a subquery combined with AND should be delivered: ${JSON.stringify(inserted)}`
  );

  unsubscribe();
}
