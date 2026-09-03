// `columns` restricts both the snapshot and the live log to a projection of
// the table (definition.ex validates it includes the primary key).

import { newStream, collect, waitUntil, assert, pgQuery, inserts } from "../lib/helpers.mjs";

export default async function run() {
  const stream = newStream({
    table: "conformance_items",
    columns: "id,name",
    where: "id = 40",
  });
  const { seen, unsubscribe } = collect(stream);

  await pgQuery(
    "INSERT INTO conformance_items (id, name, status, price) VALUES ($1, $2, $3, $4)",
    [40, "projected-row", "active", 999]
  );

  const inserted = await waitUntil(() => inserts(seen).find((m) => m.value?.id === 40));
  const keys = Object.keys(inserted.value).sort();
  assert(
    keys.join(",") === "id,name",
    `columns projection leaked extra fields: ${JSON.stringify(keys)}`
  );
  assert(inserted.value.name === "projected-row", `unexpected projected row: ${JSON.stringify(inserted)}`);

  unsubscribe();
}
