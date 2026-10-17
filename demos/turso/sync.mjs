// Replicates the Postgres `orders` table into an embedded Turso database.
//
// Restdis tails the Postgres WAL and serves each table as an Electric shape.
// This worker follows that shape with the stock @electric-sql/client and
// applies every insert, update and delete to a local Turso file, so the
// replica stays current without ever querying Postgres itself.
//
// The shape handle and offset are stored in the replica, so a restart
// resumes from the last change it applied instead of re-copying the table.
//
//   node sync.mjs                    RESTDIS_URL, RESTDIS_API_KEY, TURSO_PATH
//   node sync.mjs --serve 5190       also serve the replica's rows as JSON

import http from "node:http";
import { ShapeStream } from "@electric-sql/client";
import { connect } from "@tursodatabase/database";

const RESTDIS_URL = process.env.RESTDIS_URL ?? "http://localhost:4042";
const API_KEY = process.env.RESTDIS_API_KEY ?? "sk_demo";
const TURSO_PATH = process.env.TURSO_PATH ?? "replica.db";
const TABLE = "orders";
const servePort = process.argv.includes("--serve")
  ? Number(process.argv[process.argv.indexOf("--serve") + 1])
  : null;

const say = (text) => process.stdout.write(text + "\n");

const db = await connect(TURSO_PATH);
await db.exec(`
  CREATE TABLE IF NOT EXISTS ${TABLE} (
    id INTEGER PRIMARY KEY,
    customer TEXT NOT NULL,
    total INTEGER NOT NULL,
    status TEXT NOT NULL
  );
  CREATE TABLE IF NOT EXISTS _restdis_sync (
    shape TEXT PRIMARY KEY,
    handle TEXT,
    offset TEXT
  );
`);

const upsert = db.prepare(
  `INSERT INTO ${TABLE} (id, customer, total, status) VALUES (?, ?, ?, ?)
   ON CONFLICT (id) DO UPDATE SET customer = excluded.customer, total = excluded.total, status = excluded.status`
);
const remove = db.prepare(`DELETE FROM ${TABLE} WHERE id = ?`);
const saveCursor = db.prepare(
  `INSERT INTO _restdis_sync (shape, handle, offset) VALUES (?, ?, ?)
   ON CONFLICT (shape) DO UPDATE SET handle = excluded.handle, offset = excluded.offset`
);
const count = async () => (await db.prepare(`SELECT count(*) AS n FROM ${TABLE}`).get()).n;

const cursor = await db.prepare(`SELECT handle, offset FROM _restdis_sync WHERE shape = ?`).get(TABLE);
say(`$ node sync.mjs   # Restdis shape "${TABLE}" -> Turso ${TURSO_PATH}`);
say(cursor ? `resuming at offset ${cursor.offset} (${await count()} rows already replicated)` : "no cursor yet: taking the initial snapshot");

const stream = new ShapeStream({
  url: `${RESTDIS_URL}/v1/shape`,
  // replica=full sends whole rows on update, so each change is a plain upsert.
  params: { table: TABLE, replica: "full" },
  headers: { authorization: `Bearer ${API_KEY}` },
  ...(cursor ? { handle: cursor.handle, offset: cursor.offset } : {}),
});

stream.subscribe(
  async (messages) => {
    const changes = messages.filter((m) => m.headers.operation);
    for (const msg of messages) {
      if (msg.headers.control === "must-refetch") {
        await db.exec(`DELETE FROM ${TABLE}`);
        say("must-refetch: cleared the replica, re-snapshotting");
      }
    }
    if (changes.length) {
      await db.exec("BEGIN");
      for (const { headers, value, key } of changes) {
        if (headers.operation === "delete") {
          await remove.run(value?.id ?? Number(key.replace(/\D/g, "")));
        } else {
          await upsert.run(value.id, value.customer, value.total, value.status);
        }
        const row = headers.operation === "delete" ? "" : ` ${JSON.stringify(value)}`;
        say(`  ${headers.operation.padEnd(6)} id=${value?.id ?? key}${row}`);
      }
      await db.exec("COMMIT");
    }
    if (messages.some((m) => m.headers.control === "up-to-date")) {
      await saveCursor.run(TABLE, stream.shapeHandle, stream.lastOffset);
      if (changes.length) say(`applied ${changes.length} change(s) to Turso; replica has ${await count()} rows`);
    }
  },
  (error) => say(`stream error: ${error.message}`)
);

if (servePort) {
  http
    .createServer(async (_req, res) => {
      const rows = await db.prepare(`SELECT * FROM ${TABLE} ORDER BY id`).all();
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify(rows));
    })
    .listen(servePort);
}

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => {
    stream.unsubscribeAll();
    process.exit(0);
  });
}
