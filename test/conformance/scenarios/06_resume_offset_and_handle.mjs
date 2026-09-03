// Resuming a stream with a previously-seen `handle`/`offset` catches up from
// that point instead of re-sending the whole snapshot — the scenario the TS
// client docs describe for restoring a stream after going offline.

import { newStream, collect, waitUntil, assert, pgQuery, inserts } from "../lib/helpers.mjs";

export default async function run() {
  const first = newStream({ table: "conformance_items", where: "id >= 60 AND id < 70" });
  const firstSeen = collect(first);

  await waitUntil(() => first.isUpToDate);
  const handle = first.shapeHandle;
  const offset = first.lastOffset;
  assert(handle, "stream did not expose a shapeHandle after reaching up-to-date");

  await pgQuery(
    "INSERT INTO conformance_items (id, name, status, price) VALUES ($1, $2, $3, $4)",
    [61, "seen-by-first-stream", "active", 1]
  );
  await waitUntil(() => inserts(firstSeen.seen).find((m) => m.value?.id === 61));
  firstSeen.unsubscribe();

  // Simulate a client restarting: a fresh ShapeStream resuming from the
  // handle/offset the first stream had reached before id 61 was inserted.
  const second = newStream(
    { table: "conformance_items", where: "id >= 60 AND id < 70" },
    { handle, offset }
  );
  const secondSeen = collect(second);

  const resumedInsert = await waitUntil(() => inserts(secondSeen.seen).find((m) => m.value?.id === 61));
  assert(
    resumedInsert.value.name === "seen-by-first-stream",
    `resumed stream carried the wrong row: ${JSON.stringify(resumedInsert)}`
  );
  assert(
    inserts(secondSeen.seen).filter((m) => m.value?.id === 61).length === 1,
    "resuming from a handle/offset re-delivered the same insert more than once"
  );

  secondSeen.unsubscribe();
}
