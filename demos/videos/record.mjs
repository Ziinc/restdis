// Records the three demos as compressed GIFs in docs/demos/. Needs ffmpeg.
//
// Needs the stack (docker compose up -d && tenant.sql) and the stage server
// (node stage.mjs) running. Each demo starts from a fresh Restdis container,
// so the first read is always a cold cache.
//
//   node record.mjs              all three
//   node record.mjs query db     a subset

import { execFileSync } from "node:child_process";
import { mkdirSync, renameSync, rmSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import gifsicle from "gifsicle";
import { chromium } from "playwright";

const here = dirname(fileURLToPath(import.meta.url));
const OUT = join(here, "..", "..", "docs", "demos");
const STAGE = process.env.STAGE_URL ?? "http://localhost:5180";
const RESTDIS_URL = process.env.RESTDIS_URL ?? "http://localhost:4042";
const PGRST_URL = process.env.PGRST_URL ?? "http://localhost:3002";
const SIZE = { width: 1600, height: 900 };
const GIF_WIDTH = 1600;
const GIF_FPS = 5;
const GIF_LOSSY = 80;
const GIF_COLORS = 64;

const plural = (n, word) => `${n} ${word}${n === "1" ? "" : "s"}`;
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function pgrst(method, path, body, prefer = "return=minimal") {
  await fetch(`${PGRST_URL}/${path}`, {
    method,
    headers: { "content-type": "application/json", prefer },
    body: body && JSON.stringify(body),
  });
}

async function freshRestdis() {
  await pgrst("PATCH", "products?id=eq.1", { price: 300 });
  await pgrst("DELETE", "todos?id=gt.2");
  await pgrst(
    "POST",
    "todos",
    [
      { id: 1, title: "Point the app at Restdis", done: true },
      { id: 2, title: "Delete the hand-written cache code", done: false },
    ],
    "resolution=merge-duplicates,return=minimal"
  );
  await pgrst("DELETE", "orders?id=gt.3");
  await pgrst(
    "POST",
    "orders",
    [
      { id: 1, customer: "Ada", total: 1200, status: "paid" },
      { id: 2, customer: "Grace", total: 450, status: "pending" },
      { id: 3, customer: "Linus", total: 3000, status: "paid" },
    ],
    "resolution=merge-duplicates,return=minimal"
  );
  execFileSync("docker", ["compose", "up", "-d", "--force-recreate", "--no-deps", "restdis"], {
    cwd: here,
    stdio: "ignore",
  });
  for (let i = 0; i < 60; i++) {
    try {
      if ((await fetch(`${RESTDIS_URL}/health`)).ok) break;
    } catch {}
    await sleep(1000);
  }
  // Let the WAL tailer catch up on the reset writes before recording.
  await sleep(4000);
}

const counts = (page) =>
  page.evaluate(() => ({
    reads: document.getElementById("pg-reads").textContent,
    writes: document.getElementById("pg-writes").textContent,
    served: document.getElementById("restdis-count")?.textContent,
  }));

const DEMOS = {
  async query(page, caption) {
    const app = page.frameLocator("#app");
    const refetch = () => app.locator("#refetch").click();

    await caption("supabase-js inside TanStack Query. A fetch adapter sends its reads through Restdis.");
    await sleep(3500);
    await caption("1 · First fetch: cache MISS. Restdis asks PostgREST, and Postgres runs one SELECT.");
    await sleep(4000);
    await caption("2 · refetch() five times: every fetch is a HIT from Restdis memory. Postgres sees none of them.");
    for (let i = 0; i < 5; i++) {
      await refetch();
      await sleep(1000);
    }
    await sleep(2000);
    await caption("3 · Another service updates the Espresso price in Postgres, through PostgREST.");
    await app.locator("#write").click();
    await sleep(3500);
    await caption("4 · Restdis read the UPDATE from the WAL and evicted the entry. Next fetch: MISS, new price.");
    await refetch();
    await sleep(4000);
    await caption("5 · And back to cache HITs.");
    for (let i = 0; i < 2; i++) {
      await refetch();
      await sleep(1000);
    }
    await sleep(1500);
    const fetches = await app.locator("#console .req.settled").count();
    const { reads } = await counts(page);
    await caption(`${fetches} fetches, ${plural(reads, "SELECT")} in Postgres. The app has no cache-invalidation code.`);
    await sleep(4500);
  },

  async db(page, caption) {
    const app = page.frameLocator("#app");
    const write = async (id, text) => {
      await caption(text);
      await app.locator(`#${id}`).click();
      await sleep(4000);
    };

    await caption("Two stock TanStack DB clients. Each Electric collection's shape URL points at Restdis.");
    await sleep(4000);
    await sleep(1000);
    const { reads: snapshotReads } = await counts(page);
    await caption(
      `Each client snapshots the shape (${plural(snapshotReads, "SELECT")} in Postgres), then holds a live poll open on Restdis.`
    );
    await sleep(4500);
    await write("add", "insert: Restdis reads it from the WAL and answers both open polls.");
    await write("rename", "update: the new title reaches both clients in the next poll response.");
    await write("complete", "update: todo 2 is done, so each client's filtered live query drops it.");
    await write("bulk", "insert 3: one request, three rows. Restdis reads each new row once, for both clients.");
    await write("remove", "delete: the WAL carries the old row, so both clients drop todo 1.");
    const polls = await app.locator("#console .req.settled .count").count();
    const { reads, writes } = await counts(page);
    await caption(
      `${polls} shape responses served by Restdis for ${plural(writes, "write")}. Postgres ran ${plural(reads, "read")}.`
    );
    await sleep(5000);
  },

  async redis(page, caption) {
    await caption("ioredis, a stock Redis client, sends ordinary commands to Restdis's RESP port.");
    await sleep(1000);
    await page.evaluate(() => window.startRedisClient());
    await sleep(1500);
    const commands = await page.evaluate(
      () => document.getElementById("client").textContent.split("\n").filter((l) => /^> [A-Z]/.test(l) && !l.startsWith("> PATCH")).length
    );
    const { reads } = await counts(page);
    await caption(`${commands} Redis commands, ${plural(reads, "SELECT")} in Postgres. Restdis kept the cache fresh from the WAL.`);
    await sleep(4500);
  },

  async turso(page, caption) {
    const write = async (text, method, path, body) => {
      await caption(text);
      await pgrst(method, path, body);
      await sleep(4000);
    };

    await caption("A Node worker follows Restdis's Electric shape for orders and writes each change into embedded Turso.");
    await page.evaluate(() => window.startTurso(false));
    await sleep(5000);
    await write("insert in Postgres: Restdis reads it from the WAL, the worker applies it to Turso.", "POST", "orders", {
      id: 4, customer: "Margaret", total: 980, status: "pending",
    });
    await write("update: the whole new row arrives (replica=full), so the worker just upserts it.", "PATCH", "orders?id=eq.2", {
      status: "paid",
    });
    await write("insert 3 rows in one statement: each poll's batch lands in Turso as one transaction.", "POST", "orders", [
      { id: 5, customer: "Alan", total: 2100, status: "pending" },
      { id: 6, customer: "Barbara", total: 640, status: "paid" },
      { id: 7, customer: "Edsger", total: 1500, status: "pending" },
    ]);
    await write("delete: the row leaves Turso too.", "DELETE", "orders?id=eq.1");

    await caption("Stop the worker. Writes keep landing in Postgres while it is down.");
    await page.evaluate(() => window.stopTurso());
    await sleep(1500);
    await pgrst("PATCH", "orders?id=eq.4", { status: "paid" });
    await pgrst("POST", "orders", { id: 8, customer: "Donald", total: 330, status: "pending" });
    await sleep(3500);
    await caption("Restart: the worker resumes from the shape offset it stored in Turso and catches up.");
    await page.evaluate(() => window.startTurso(true));
    await sleep(6000);

    const same = await page.evaluate(
      () => JSON.stringify(window.tursoRows()) === JSON.stringify(window.pgRows())
    );
    const rows = await page.evaluate(() => window.tursoRows().length);
    const { reads } = await counts(page);
    await caption(
      same
        ? `Turso matches Postgres: ${plural(String(rows), "row")}. Postgres served ${plural(reads, "read")}; the worker never connected to it.`
        : "Turso has not caught up with Postgres yet."
    );
    await sleep(5000);
  },
};

const wanted = process.argv.slice(2).length ? process.argv.slice(2) : Object.keys(DEMOS);
mkdirSync(OUT, { recursive: true });
const browser = await chromium.launch({ executablePath: process.env.CHROMIUM_PATH });

for (const name of wanted) {
  console.log(`recording ${name}...`);
  await freshRestdis();
  const tmp = join(here, ".recordings", name);
  rmSync(tmp, { recursive: true, force: true });
  const context = await browser.newContext({ viewport: SIZE, recordVideo: { dir: tmp, size: SIZE } });
  // A stepped highlight instead of a fade: the same cue in two frames, which
  // keeps the GIF small.
  await context.addInitScript(() => {
    document.addEventListener("DOMContentLoaded", () => {
      const style = document.createElement("style");
      style.textContent = ".flash { animation-timing-function: steps(1, end) !important; }";
      document.head.appendChild(style);
    });
  });
  const page = await context.newPage();
  await page.goto(`${STAGE}/?demo=${name}`);
  await page.waitForFunction(() => window.leftReady);
  await DEMOS[name](page, (text) => page.evaluate((t) => window.setCaption(t), text));
  const video = page.video();
  await context.close();
  const webm = join(here, ".recordings", `${name}.webm`);
  renameSync(await video.path(), webm);
  // GitHub autoplays GIFs inline. A small palette and gifsicle's lossy pass keep
  // each one light enough for the README.
  const gif = join(OUT, `${name}.gif`);
  execFileSync("ffmpeg", [
    "-v", "error", "-y", "-i", webm, "-vf",
    `fps=${GIF_FPS},scale=${GIF_WIDTH}:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=${GIF_COLORS}:stats_mode=diff[p];[b][p]paletteuse=dither=none:diff_mode=rectangle`,
    gif,
  ]);
  execFileSync(gifsicle, ["-O3", `--lossy=${GIF_LOSSY}`, "--batch", gif]);
  console.log(`  wrote ${gif} (${(statSync(gif).size / 1e6).toFixed(1)} MB)`);
}

await browser.close();
