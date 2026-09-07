// `where` clause filtering (RestdisElectric.Eval / the Rustler evaluator).
// A row entering the filter's match set is logged as an insert even if the
// underlying SQL statement was an UPDATE, and a row leaving it is logged as
// a delete even though it still exists in Postgres. See wal.ex's
// `logged_operation/2` and ELECTRIC_PRD.md's `where` phase.

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
    where: "status = 'active' AND id >= 20 AND id < 30",
  });
  const { seen, unsubscribe } = collect(stream);

  // Seeded row 1 (active) is outside the id >= 20 window, seeded row 2
  // (inactive) would fail both filters — snapshot should be empty of them.
  const snapshotSettled = await waitUntil(() =>
    seen.some((m) => m.headers?.control === "up-to-date") ? seen.slice() : null
  );
  assert(
    !snapshotSettled.some((m) => m.value?.id === 1 || m.value?.id === 2),
    `snapshot leaked a row outside the where clause: ${JSON.stringify(snapshotSettled)}`
  );

  // A row that never matches must never produce an insert.
  await pgQuery(
    "INSERT INTO conformance_items (id, name, status, price) VALUES ($1, $2, $3, $4)",
    [21, "inactive-in-range", "inactive", 10]
  );

  // A matching row does produce an insert; wait for it as the "has the
  // non-matching insert above had time to (wrongly) appear" checkpoint.
  await pgQuery(
    "INSERT INTO conformance_items (id, name, status, price) VALUES ($1, $2, $3, $4)",
    [22, "active-in-range", "active", 10]
  );
  await waitUntil(() => inserts(seen).find((m) => m.value?.id === 22));
  assert(
    !inserts(seen).some((m) => m.value?.id === 21),
    `a non-matching row was delivered as an insert: ${JSON.stringify(inserts(seen))}`
  );

  // Update that moves id 22 out of the filter (active -> inactive) is
  // logged as a delete, not an update.
  await pgQuery("UPDATE conformance_items SET status = 'inactive' WHERE id = 22");
  await waitUntil(() => deletes(seen).find((m) => m.value?.id === 22 || m.old_value?.id === 22));
  assert(
    !seen.some((m) => m.headers?.operation === "update" && m.value?.id === 22),
    "an out-of-filter transition was logged as update instead of delete"
  );

  // Update that moves id 21 into the filter (inactive -> active) is logged
  // as an insert, not an update.
  await pgQuery("UPDATE conformance_items SET status = 'active' WHERE id = 21");
  const enteredFilter = await waitUntil(() => inserts(seen).find((m) => m.value?.id === 21));
  assert(
    enteredFilter.value.status === "active",
    `entering the filter did not carry the current row: ${JSON.stringify(enteredFilter)}`
  );

  unsubscribe();
}
