// Conformance check for Phase 6 item 7 of ELECTRIC_PRD.md.
//
// Uses the real, published @electric-sql/client package (pinned in
// package.json) against a running Restdis instance to prove that:
//   1. ShapeStream reads an initial snapshot of a table through /v1/shape.
//   2. A live write reaches a subscribed client without a page reload.
//
// This does not replace Restdis's own ExUnit suite. It is the minimum needed
// to catch a real protocol regression that only shows up against the actual
// client library, which is the gap `mix test` cannot cover on its own.

import { ShapeStream } from "@electric-sql/client";
import pg from "pg";

const BASE_URL = process.env.RESTDIS_URL ?? "http://localhost:4040";
const API_KEY = process.env.RESTDIS_API_KEY ?? "sk_conformance";
const DATABASE_URL =
  process.env.CONFORMANCE_DATABASE_URL ??
  "postgres://postgres:postgres@localhost:5432/restdis_dev";

function fail(message) {
  console.error(`FAIL: ${message}`);
  process.exit(1);
}

async function waitForMessages(stream, predicate, timeoutMs) {
  return new Promise((resolve, reject) => {
    const seen = [];
    const timer = setTimeout(() => {
      unsubscribe();
      reject(new Error(`timed out after ${timeoutMs}ms, saw: ${JSON.stringify(seen)}`));
    }, timeoutMs);

    const unsubscribe = stream.subscribe((messages) => {
      seen.push(...messages);
      const match = predicate(seen);
      if (match) {
        clearTimeout(timer);
        unsubscribe();
        resolve(match);
      }
    });
  });
}

async function main() {
  const stream = new ShapeStream({
    url: `${BASE_URL}/v1/shape`,
    params: { table: "conformance_widgets" },
    headers: { authorization: `Bearer ${API_KEY}` },
  });

  console.log("Waiting for the initial snapshot...");
  const snapshotRows = await waitForMessages(
    stream,
    (messages) => {
      const inserts = messages.filter((m) => m.headers?.operation === "insert");
      return inserts.length > 0 ? inserts : null;
    },
    15_000
  );

  const seeded = snapshotRows.find((m) => m.value?.id === 1);
  if (!seeded || seeded.value.name !== "first widget") {
    fail(`snapshot did not contain the seeded row: ${JSON.stringify(snapshotRows)}`);
  }
  console.log("OK: snapshot contains the seeded row.");

  console.log("Writing a new row directly to Postgres...");
  const client = new pg.Client({ connectionString: DATABASE_URL });
  await client.connect();
  await client.query(
    "INSERT INTO conformance_widgets (id, name) VALUES ($1, $2)",
    [2, "second widget"]
  );
  await client.end();

  console.log("Waiting for the live update...");
  const liveRows = await waitForMessages(
    stream,
    (messages) => {
      const match = messages.find(
        (m) => m.headers?.operation === "insert" && m.value?.id === 2
      );
      return match ? [match] : null;
    },
    20_000
  );

  if (liveRows[0].value.name !== "second widget") {
    fail(`live update carried the wrong row: ${JSON.stringify(liveRows)}`);
  }
  console.log("OK: the live write reached the client.");

  console.log("PASS: @electric-sql/client is protocol-compatible with this build of Restdis.");
  process.exit(0);
}

main().catch((error) => {
  fail(error.stack ?? String(error));
});
