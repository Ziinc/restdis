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
// Every scenario here now exercises an implemented behaviour: gatekeeper
// mode and open mode's shared secret (ELECTRIC_PRD.md's Authentication
// section) shipped in Phase 7, and a subquery combined with one
// subquery-free predicate over AND/OR (ELECTRIC_PRD.md Phase 6 item 1,
// extended) is tracked by RestdisElectric.SubqueryTracker. A scenario for a
// documented behaviour that is not implemented yet can be marked `export
// const xfail = "reason"`; the runner reports it as XFAIL rather than FAIL,
// but flags an unexpectedly-passing xfail (XPASS) as a failure so the day a
// gap closes gets noticed and the marker removed.
//
// This does not replace Restdis's own ExUnit suite (see
// apps/restdis_server/test/http/electric_test.exs for status-code-level
// coverage). It is the minimum needed to catch a real protocol regression
// that only shows up against the actual client library, which `mix test`
// cannot cover on its own.

import { readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { ConformanceError } from "./lib/helpers.mjs";

const scenariosDir = path.join(path.dirname(fileURLToPath(import.meta.url)), "scenarios");

// Backstop for a scenario that forgets to bound one of its own awaits (see
// 08_shape_class.mjs's history): every scenario gets a hard ceiling here so
// one hung stream fails just that scenario instead of the whole suite, no
// matter what the scenario itself does or doesn't await with a timeout.
// Kept well above the longest waitUntil timeout any scenario actually uses
// (20s) but small enough that every scenario hitting the backstop at once
// still fits inside the workflow's per-step timeout.
const SCENARIO_TIMEOUT_MS = Number(process.env.CONFORMANCE_SCENARIO_TIMEOUT_MS ?? 25_000);

async function runWithDeadline(fn, label) {
  let timer;
  try {
    return await Promise.race([
      fn(),
      new Promise((_, reject) => {
        timer = setTimeout(
          () =>
            reject(
              new ConformanceError(
                `${label} did not finish within ${SCENARIO_TIMEOUT_MS}ms (suite-wide backstop)`
              )
            ),
          SCENARIO_TIMEOUT_MS
        );
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

async function main() {
  const files = readdirSync(scenariosDir)
    .filter((name) => name.endsWith(".mjs"))
    .sort();

  let failures = 0;

  for (const file of files) {
    const label = file.replace(/\.mjs$/, "");
    process.stdout.write(`RUN  ${label} ... `);
    const module = await import(path.join(scenariosDir, file));
    const xfail = module.xfail;

    try {
      await runWithDeadline(module.default, label);
      if (xfail) {
        failures += 1;
        console.log("XPASS");
        console.error(
          `${label} was marked xfail (${xfail}) but passed — the gap it documents looks closed; remove the xfail marker.`
        );
      } else {
        console.log("PASS");
      }
    } catch (error) {
      if (xfail) {
        console.log(`XFAIL (${xfail})`);
      } else {
        failures += 1;
        console.log("FAIL");
        console.error(error.stack ?? String(error));
      }
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
