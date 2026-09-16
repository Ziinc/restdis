// A `field IN (subquery)` clause combined with one subquery-free predicate
// over AND (ELECTRIC_PRD.md Phase 6 item 1, extended): RestdisElectric.
// SubqueryTracker incrementally tracks the subquery's own table
// (`conformance_subquery_source`) and re-checks the rest of the clause
// (`status = 'active'`) against each affected row of `conformance_items`
// before emitting an insert/delete, rather than only supporting the bare
// `field IN (subquery)` form.

import {
  newStream,
  collect,
  waitUntil,
  assert,
  pgQuery,
  inserts,
  deletes,
} from "../lib/helpers.mjs";

export default async function run() {
  const stream = newStream({
    table: "conformance_items",
    where:
      "status = 'active' AND id IN (SELECT id FROM conformance_subquery_source WHERE enabled = true)",
  });
  const { seen, unsubscribe } = collect(stream);

  // id 90 is enabled in the subquery source; id 91 is not. Only 90 should
  // ever be delivered once both are inserted as 'active'.
  await pgQuery(
    "INSERT INTO conformance_items (id, name, status, price) VALUES ($1, $2, $3, $4)",
    [90, "enabled-in-subquery", "active", 1]
  );
  await pgQuery(
    "INSERT INTO conformance_items (id, name, status, price) VALUES ($1, $2, $3, $4)",
    [91, "disabled-in-subquery", "active", 1]
  );
  await waitUntil(() => inserts(seen).find((m) => m.value?.id === 90));
  assert(
    !inserts(seen).some((m) => m.value?.id === 91),
    `a row failing the subquery half of the clause should never be delivered: ${JSON.stringify(inserts(seen))}`
  );

  // Flip 90 out of the subquery: the rest of the clause ('active') still
  // holds, so the tracker must emit a delete for it.
  await pgQuery("UPDATE conformance_subquery_source SET enabled = false WHERE id = 90");
  await waitUntil(() => deletes(seen).find((m) => m.value?.id === 90 || m.old_value?.id === 90));

  // Flip 91 into the subquery: the rest of the clause already holds, so the
  // tracker must emit an insert for it now.
  await pgQuery("UPDATE conformance_subquery_source SET enabled = true WHERE id = 91");
  const lateInsert = await waitUntil(() => inserts(seen).find((m) => m.value?.id === 91));
  assert(
    lateInsert.value.name === "disabled-in-subquery",
    `late-enabled row was delivered with the wrong data: ${JSON.stringify(lateInsert)}`
  );

  unsubscribe();
}
