// Initial snapshot and a live insert reaching a subscribed client, against
// `conformance_widgets`. See ELECTRIC_PRD.md Phase 6 item 7.

import { newStream, collect, waitUntil, assert, pgQuery, inserts } from "../lib/helpers.mjs";

export default async function run() {
  const stream = newStream({ table: "conformance_widgets" });
  const { seen, unsubscribe } = collect(stream);

  const snapshotInsert = await waitUntil(
    () => inserts(seen).find((m) => m.value?.id === 1),
    { timeoutMs: 15_000 }
  );
  assert(
    snapshotInsert.value.name === "first widget",
    `snapshot row 1 had the wrong name: ${JSON.stringify(snapshotInsert)}`
  );

  await pgQuery("INSERT INTO conformance_widgets (id, name) VALUES ($1, $2)", [
    2,
    "second widget",
  ]);

  const liveInsert = await waitUntil(
    () => inserts(seen).find((m) => m.value?.id === 2),
    { timeoutMs: 20_000 }
  );
  assert(
    liveInsert.value.name === "second widget",
    `live insert carried the wrong row: ${JSON.stringify(liveInsert)}`
  );

  unsubscribe();
}
