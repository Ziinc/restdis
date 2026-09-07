import { describe, expect, it } from "vitest";

const AUTH_URL = process.env.DEMO_AUTH_URL ?? "http://localhost:9999";

// Restdis does not yet proxy Auth (SUPABASE_INTEGRATION_PRD.md Auth caching
// is unimplemented), so this only proves the demo stack wires up a real
// GoTrue instance for that work to target later.
describe("GoTrue (demo stack wiring)", () => {
  it("is reachable", async () => {
    const res = await fetch(`${AUTH_URL}/health`);
    expect(res.status).toBe(200);
  });
});
