// Demo 3: a stock Redis client (ioredis) talking to Restdis's RESP port.
// stage.mjs streams this script's output into the left-hand terminal.

import Redis from "ioredis";

const PGRST_URL = process.env.PGRST_URL ?? "http://localhost:3001";
const PATH = "products?select=id,name,price&order=id";

const redis = new Redis({
  host: process.env.RESP_HOST ?? "localhost",
  port: Number(process.env.RESP_PORT ?? 6382),
  password: process.env.RESTDIS_API_KEY ?? "sk_demo",
  enableReadyCheck: false,
  // ioredis 6 opens with `HELLO 3 AUTH ...`. Restdis speaks RESP2 and answers
  // HELLO with NOAUTH, which ioredis does not treat as "no RESP3", so pin RESP2.
  protocol: 2,
});

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const say = (text) => process.stdout.write(text + "\n");

async function run(label, fn) {
  const started = performance.now();
  const result = await fn();
  const ms = (performance.now() - started).toFixed(2);
  say(`> ${label}`);
  say(`  ${result === null ? "(nil)" : summarize(result)}   (${ms} ms)`);
  return result;
}

function summarize(value) {
  if (typeof value !== "string" || !value.startsWith("[")) return String(value);
  return JSON.parse(value)
    .map((p) => `${p.name} $${(p.price / 100).toFixed(2)}`)
    .join(", ");
}

say("$ node redis-client.mjs   # ioredis, connected to restdis:6382");
say("");
await sleep(1500);

say("# Cache a PostgREST query. First call: cache miss, Restdis asks Postgres.");
const key = await run(`PGRST.QUERY ${PATH} TTL 300`, () =>
  redis.call("PGRST.QUERY", PATH, "TTL", "300")
);
await sleep(2500);

say("");
say("# Plain GETs on the returned key. Served from Restdis memory.");
for (let i = 0; i < 5; i++) {
  await run(`GET ${key}`, () => redis.get(key));
  await sleep(700);
}
await sleep(1800);

say("");
say("# Another service writes to Postgres through PostgREST, not Restdis.");
say("> PATCH /products?id=eq.1  {\"price\": 350}");
await fetch(`${PGRST_URL}/products?id=eq.1`, {
  method: "PATCH",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ price: 350 }),
});
await sleep(2500);

say("");
say("# Restdis read the write from the WAL and evicted the stale entry.");
await run(`GET ${key}`, () => redis.get(key));
await sleep(2000);

say("");
say("# Re-cache: one more trip to Postgres, with the new price.");
await run(`PGRST.QUERY ${PATH} TTL 300`, () => redis.call("PGRST.QUERY", PATH, "TTL", "300"));
await sleep(1200);
for (let i = 0; i < 3; i++) {
  await run(`GET ${key}`, () => redis.get(key));
  await sleep(700);
}

say("");
say("# Done. Compare with the Postgres log on the right.");
// Restdis does not implement QUIT, so close the socket directly.
redis.disconnect();
