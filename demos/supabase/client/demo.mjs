// Calls the wrapper in restdis-supabase.mjs against a running demo stack
// (../docker-compose.yml). Run this after `docker compose up -d --build` in
// the `demos/supabase` directory, or via `demos/supabase/demo.sh` which runs
// it as one step of the full narrated walkthrough.

import { createRestdisClient } from "./restdis-supabase.mjs";

const SUPABASE_URL = process.env.DEMO_PGRST_URL ?? "http://localhost:3000";
const SUPABASE_KEY = process.env.DEMO_API_KEY ?? "sk_demo";

const supabase = createRestdisClient(SUPABASE_URL, SUPABASE_KEY);

function logResult(label, result) {
  console.log(`\n${label}`);
  if (result.intercepted) {
    console.log(`  intercepted by: ${result.via} (cache=${result.cache})`);
    console.log(`  sc-cache: ${result.cacheStatus}, sc-cache-ttl: ${result.cacheTtlRemaining}`);
  } else {
    console.log("  not intercepted: went straight to the real client");
  }
  console.log(`  status: ${result.status ?? "n/a"}`);
  console.log(`  data: ${JSON.stringify(result.data)}`);
  if (result.error) console.log(`  error: ${JSON.stringify(result.error)}`);
}

async function main() {
  console.log("=== supabase-js wrapper: cache option demo ===");

  console.log("\nsupabase.from('widgets').select('id,name') — no cache option");
  console.log(
    "  (goes straight through the real supabase-js client; this demo stack fronts bare\n" +
      "  PostgREST with no Kong/rest-v1 gateway, so expect a 404 here rather than the\n" +
      "  200 you'd see against a real Supabase project URL - the interception below is\n" +
      "  the point of this demo, not this call)"
  );
  const direct = await supabase.from("widgets").select("id,name");
  logResult("Direct call (real supabase-js -> PostgREST)", direct);

  console.log(
    "\nsupabase.from('widgets').select('id,name', { cache: '30s' }) — first call, cache miss"
  );
  const first = await supabase.from("widgets").select("id,name", { cache: "30s" });
  logResult("Intercepted call #1", first);

  console.log(
    "\nsupabase.from('widgets').select('id,name', { cache: '30s' }) — repeat call, cache hit"
  );
  const second = await supabase.from("widgets").select("id,name", { cache: "30s" });
  logResult("Intercepted call #2", second);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
