// Records the three demos as MP4 and GIF in docs/demos/. Needs ffmpeg.
//
// Needs the stack (docker compose up -d && tenant.sql) and the stage server
// (node stage.mjs) running. Each demo starts from a fresh Restdis container,
// so the first read is always a cold cache.
//
//   node record.mjs              all three
//   node record.mjs query db     a subset

import { execFileSync } from "node:child_process";
import { mkdirSync, renameSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const here = dirname(fileURLToPath(import.meta.url));
const OUT = join(here, "..", "..", "docs", "demos");
const STAGE = process.env.STAGE_URL ?? "http://localhost:5180";
const RESTDIS_URL = process.env.RESTDIS_URL ?? "http://localhost:4042";
const PGRST_URL = process.env.PGRST_URL ?? "http://localhost:3001";
const SIZE = { width: 1600, height: 900 };

const plural = (n, word) => `${n} ${word}${n === "1" ? "" : "s"}`;
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function pgrst(method, path, body) {
  await fetch(`${PGRST_URL}/${path}`, {
    method,
    headers: { "content-type": "application/json" },
    body: body && JSON.stringify(body),
  });
}

async function freshRestdis() {
  await pgrst("PATCH", "products?id=eq.1", { price: 300 });
  await pgrst("DELETE", "todos?id=gt.2");
  await pgrst("PATCH", "todos?id=eq.2", { done: false });
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

    await caption("A stock TanStack Query app. useQuery points at Restdis instead of PostgREST.");
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
    const fetches = await app.locator(".log tbody tr").count();
    const { reads } = await counts(page);
    await caption(`${fetches} fetches, ${plural(reads, "SELECT")} in Postgres. The app has no cache-busting code.`);
    await sleep(4500);
  },

  async db(page, caption) {
    const app = page.frameLocator("#app");

    await caption("A stock TanStack DB app. Its Electric collection's shape URL points at Restdis.");
    await sleep(3500);
    await caption("1 · Initial sync: Restdis snapshots the todos table once, through PostgREST.");
    await sleep(4000);
    await caption("2 · The client now holds a live long-poll open on Restdis. Nothing reaches Postgres while idle.");
    await sleep(4500);
    await caption("3 · Another user inserts a todo, writing to Postgres through PostgREST.");
    await app.locator("#add").click();
    await sleep(2500);
    await caption("4 · Restdis saw the INSERT in the WAL, read just that row by primary key, and pushed it to the shape.");
    await sleep(4000);
    await caption("5 · Another user completes todo 2. The filtered live query updates too.");
    await app.locator("#complete").click();
    await sleep(4500);
    await caption(`One snapshot, then one primary-key read per write. The client never polls. Only the shape URL changed.`);
    await sleep(4500);
  },

  async redis(page, caption) {
    await caption("ioredis, a stock Redis client, sends ordinary commands to Restdis's RESP port.");
    await sleep(1000);
    await page.evaluate(() => window.startRedisClient());
    await sleep(1500);
    const { reads } = await counts(page);
    await caption(`11 Redis commands, ${plural(reads, "SELECT")} in Postgres. Restdis kept the cache fresh from the WAL.`);
    await sleep(4500);
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
  const page = await context.newPage();
  await page.goto(`${STAGE}/?demo=${name}`);
  await page.waitForFunction(() => window.leftReady);
  await DEMOS[name](page, (text) => page.evaluate((t) => window.setCaption(t), text));
  const video = page.video();
  await context.close();
  const webm = join(OUT, `${name}.webm`);
  renameSync(await video.path(), webm);
  // MP4 for full quality, GIF so GitHub can show it inline in the README.
  const ffmpeg = (...args) => execFileSync("ffmpeg", ["-v", "error", "-y", "-i", webm, ...args]);
  ffmpeg("-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "26", "-preset", "slow", "-movflags", "+faststart", join(OUT, `${name}.mp4`));
  ffmpeg(
    "-vf",
    "fps=8,scale=1200:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=96:stats_mode=diff[p];[b][p]paletteuse=dither=none:diff_mode=rectangle",
    join(OUT, `${name}.gif`)
  );
  rmSync(webm);
  console.log(`  wrote ${join(OUT, name)}.{mp4,gif}`);
}

await browser.close();
