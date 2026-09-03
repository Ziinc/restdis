// The higher-level `Shape` materialised-view API layered on ShapeStream —
// the primitive the TS docs recommend building framework hooks on top of.

import { Shape } from "@electric-sql/client";
import { newStream, waitUntil, assert, pgQuery } from "../lib/helpers.mjs";

export default async function run() {
  const stream = newStream({ table: "conformance_items", where: "id >= 80 AND id < 90" });
  const shape = new Shape(stream);

  const initialRows = await shape.rows;
  assert(Array.isArray(initialRows), "Shape.rows did not resolve to an array");

  await pgQuery(
    "INSERT INTO conformance_items (id, name, status, price) VALUES ($1, $2, $3, $4)",
    [81, "shape-class-row", "active", 1]
  );

  await waitUntil(() => shape.currentRows.some((row) => row.id === 81));
  const value = await shape.value;
  assert(value instanceof Map, "Shape.value did not resolve to a Map");
  const row = [...value.values()].find((row) => row.id === 81);
  assert(row?.name === "shape-class-row", `Shape did not materialise the inserted row: ${JSON.stringify(row)}`);

  await pgQuery("DELETE FROM conformance_items WHERE id = 81");
  await waitUntil(() => !shape.currentRows.some((row) => row.id === 81));

  shape.unsubscribeAll();
}
