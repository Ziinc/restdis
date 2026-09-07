import { beforeAll, describe, expect, it } from "vitest";
import pg from "pg";

const RESTDIS_URL = process.env.RESTDIS_URL ?? "http://localhost:4041";
const API_KEY = process.env.DEMO_API_KEY ?? "sk_demo";
const DIRECT_PG_URL =
  process.env.DEMO_DIRECT_PG_URL ?? "postgres://postgres:postgres@localhost:5433/postgres";

function fetchWidgets() {
  const path = encodeURIComponent("widgets?select=id,name&order=id");
  return fetch(`${RESTDIS_URL}/pgrst/query?path=${path}`, {
    headers: { authorization: `Bearer ${API_KEY}` },
  });
}

// Exercises SUPABASE_INTEGRATION_PRD.md's core primitive against a real
// PostgREST origin: a GET is cached, repeat reads are served from cache, and
// a WAL-visible write busts the cached entry.
describe("PostgREST caching (real PostgREST origin)", () => {
  let client: pg.Client;

  beforeAll(async () => {
    client = new pg.Client({ connectionString: DIRECT_PG_URL });
    await client.connect();
    return () => client.end();
  });

  it("proxies a GET to the real PostgREST origin", async () => {
    const res = await fetchWidgets();
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body).toEqual(
      expect.arrayContaining([{ id: 1, name: "first widget" }, { id: 2, name: "second widget" }])
    );
  });

  it("serves a repeat GET from cache", async () => {
    const first = await fetchWidgets();
    expect(first.status).toBe(200);
    const second = await fetchWidgets();
    expect(second.status).toBe(200);
    expect(await second.json()).toEqual(await first.json());
  });

  it("busts the cached entry on a WAL-visible write", async () => {
    const before = await fetchWidgets();
    expect(await before.json()).not.toEqual(
      expect.arrayContaining([{ id: 3, name: "third widget" }])
    );

    await client.query("INSERT INTO widgets (id, name) VALUES (3, 'third widget')");

    await expect
      .poll(
        async () => {
          const res = await fetchWidgets();
          const rows = await res.json();
          return rows.some((row: { id: number }) => row.id === 3);
        },
        { timeout: 15_000, interval: 500 }
      )
      .toBe(true);
  });
});
