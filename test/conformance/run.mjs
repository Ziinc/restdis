// Full conformance suite for Phase 6 item 7 of ELECTRIC_PRD.md.
//
// Runs the real, published @electric-sql/client package (pinned in
// package.json) against a running Restdis instance, covering every
// documented behaviour of https://electric.ax/docs/sync/api/clients/typescript
// that Restdis implements: initial snapshot, live insert/update/delete,
// `where`-clause enter/exit transitions, `columns` projection, `replica=full`
// old_value, resuming from a handle/offset, must-refetch (409 + rotation),
// the `Shape` materialised-view API, and the documented error responses.
//
// This does not replace Restdis's own ExUnit suite (see
// apps/restdis_server/test/http/electric_test.exs for status-code-level
// coverage). It is the minimum needed to catch a real protocol regression
// that only shows up against the actual client library, which `mix test`
// cannot cover on its own.

import { readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const scenariosDir = path.join(path.dirname(fileURLToPath(import.meta.url)), "scenarios");

async function main() {
  const files = readdirSync(scenariosDir)
    .filter((name) => name.endsWith(".mjs"))
    .sort();

  let failures = 0;

  for (const file of files) {
    const label = file.replace(/\.mjs$/, "");
    process.stdout.write(`RUN  ${label} ... `);
    try {
      const module = await import(path.join(scenariosDir, file));
      await module.default();
      console.log("PASS");
    } catch (error) {
      failures += 1;
      console.log("FAIL");
      console.error(error.stack ?? String(error));
    }
  }

  if (failures > 0) {
    console.error(`FAIL: ${failures}/${files.length} conformance scenario(s) failed.`);
    process.exit(1);
  }

  console.log(`PASS: all ${files.length} conformance scenarios passed.`);
  console.log("@electric-sql/client is protocol-compatible with this build of Restdis.");
  process.exit(0);
}

main().catch((error) => {
  console.error("FAIL:", error.stack ?? String(error));
  process.exit(1);
});
