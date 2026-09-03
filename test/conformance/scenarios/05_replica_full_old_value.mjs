// `replica=full` attaches the pre-image on update/delete messages
// (RestdisElectric.WAL.old_value/3), requiring REPLICA IDENTITY FULL on the
// source table (already set on conformance_items in seed.sql).

import {
  newStream,
  collect,
  waitUntil,
  assert,
  pgQuery,
  updates,
  deletes,
} from "../lib/helpers.mjs";

export default async function run() {
  const stream = newStream({
    table: "conformance_items",
    replica: "full",
    where: "id = 50",
  });
  const { seen, unsubscribe } = collect(stream);

  await pgQuery(
    "INSERT INTO conformance_items (id, name, status, price) VALUES ($1, $2, $3, $4)",
    [50, "before-update", "active", 111]
  );
  await waitUntil(() => seen.some((m) => m.value?.id === 50));

  await pgQuery("UPDATE conformance_items SET price = $1 WHERE id = 50", [222]);
  const updated = await waitUntil(() => updates(seen).find((m) => m.value?.id === 50));
  assert(updated.old_value, `replica=full update carried no old_value: ${JSON.stringify(updated)}`);
  assert(
    updated.old_value.price === 111,
    `old_value had the wrong price: ${JSON.stringify(updated.old_value)}`
  );
  assert(updated.value.price === 222, `new value had the wrong price: ${JSON.stringify(updated.value)}`);

  await pgQuery("DELETE FROM conformance_items WHERE id = 50");
  const deleted = await waitUntil(() => deletes(seen).find((m) => m.old_value?.id === 50));
  assert(
    deleted.old_value.price === 222,
    `delete's old_value did not carry the last known row: ${JSON.stringify(deleted)}`
  );

  unsubscribe();
}
