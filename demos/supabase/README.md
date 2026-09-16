# Supabase integration demo

Runs Restdis (built from the root `Dockerfile`) against a real PostgREST and
GoTrue, standing in for a self-hosted Supabase project. Verifies the
integration points described in `prds/SUPABASE_INTEGRATION_PRD.md` against
real origins instead of stubs. Separate from the root `docker-compose.yml`,
which is for local development against bare Postgres, and from
`demos/redis/docker-compose.yml`, which is a lighter stack for the
RESP-protocol demo (no GoTrue, Prometheus, or Grafana).

## Running locally

```sh
cd demos/supabase
docker compose up -d --build
cd tests
npm install
RESTDIS_URL=http://localhost:4041 npm test
cd ..
docker compose down -v
```

## Ports

| Service  | Port (host) |
| -------- | ----------- |
| restdis  | 4041 (HTTP), 6381 (RESP) |
| db       | 5433        |
| rest     | 3000        |
| auth     | 9999        |
| prometheus | 9090      |
| grafana  | 3001        |

These are offset from the root `docker-compose.yml`'s ports (4040, 6380,
5432) so both stacks can run side by side. They match `demos/redis`'s ports,
so don't run both stacks at once.

## supabase-js wrapper

`client/restdis-supabase.mjs` wraps the real `@supabase/supabase-js` client.
`.from(table).select(columns)` behaves exactly like the real client normally
would. Add `{ cache: '30s' }` to `select()`'s options and the request is
rerouted through Restdis's `/pgrst/query` cache instead of going straight to
PostgREST - the point being to show the interception happening from an
application's normal call shape, not a bespoke test client.

```sh
cd demos/supabase/client
npm install
node demo.mjs
```

Not shipped code - it's the minimum needed to demonstrate the cache option
against a real client for the demo script and screen recording below.

## Grafana: live internals, single page

`grafana/dashboards/restdis-demo.json` is a compact, six-panel dashboard
meant to sit open in a browser pane (e.g. on the left, next to the terminal
running `demo.sh`) for the whole recording, with no scrolling and no manual
import - Prometheus (2s scrape interval) and Grafana (1s dashboard refresh,
anonymous viewer access) are both part of `docker-compose.yml` and provision
themselves on `docker compose up`.

Open http://localhost:3001/d/restdis-demo (`demo.sh` does this for you
automatically at startup). It covers exactly the flow the demo script
drives - a write landing, the WAL tailer picking it up, the reverse index
resolving what to bust, and the resulting invalidation latency:

| Panel | Metric | What to watch for |
| --- | --- | --- |
| WAL ingest throughput | `restdis_buster.wal.received.bytes` | spikes the instant the demo's `update widgets ... where id = 1` commits |
| WAL events processed | `restdis_buster.event.processed.count` | shows up as `op="update" table="widgets"` |
| WAL tailer lag | `restdis_buster.tailer.lag.lag_us` | should stay near zero throughout |
| Invalidation latency | `restdis_buster.invalidation.latency.duration_us` | the headline number: write-to-bust time, p50/p95/p99 |
| Reverse index hit/miss | `restdis_buster.reverse_index.{hit,miss}` | a hit on `widgets` right after the update is the reverse index doing its job |
| Persisted cache entries, all tenants | `restdis.persist.count.count` | one line per tenant; a burst of new lines during the load test below |

This is a demo-scoped subset, not a replacement for the full operational
dashboard at `grafana/restdis-dashboard.json` in the repo root (cluster
distribution, rewarm, disk cache, VM, Electric shapes) - that one is built to
be scrolled and covers everything Restdis emits, not just what a five-minute
recording needs on screen at once.

## Screen-recording walkthrough

`demo.sh` is a narrated, pause-between-steps script for recording a demo:
origin PostgREST query -> cache miss through Restdis -> cache hit -> direct
write to Postgres -> WAL-driven cache bust -> GoTrue reachability.

```sh
cd demos/supabase
./demo.sh              # brings the stack up, then walks through it,
                        # pausing for enter between steps
./demo.sh --no-up      # stack already running, skip straight to the walkthrough
DEMO_AUTOPLAY=1 ./demo.sh   # no keypresses; sleeps between steps instead
```

Requires `curl`, `psql`, `node`, and `docker compose` on `PATH`.

## Load test: many tenants, many requests, high speed

`load-test.mjs` seeds a batch of synthetic tenants (`load-tenant-0`,
`load-tenant-1`, ...), all sharing the demo's `widgets` origin table, then
fires many concurrent requests spread across all of them against Restdis's
PGRST cache for a fixed duration - a live-load moment for the recording,
timed right after the Grafana dashboard has been introduced and just before
the GoTrue step. `demo.sh` runs it as step 8. Standalone:

```sh
cd demos/supabase
LOAD_TENANTS=10 LOAD_CONCURRENCY=50 LOAD_DURATION_S=15 node load-test.mjs
```

Prints live throughput (`req/s`) to the terminal; on the Grafana side, watch
the WAL/event-processed panels stay essentially flat (every request after
each tenant's first is a cache hit - no origin traffic) while "Persisted
cache entries, across all tenants" gets one new line per tenant. This is a
demonstration, not a benchmark: throughput depends entirely on the host
running the stack. No npm dependencies - shells out to `psql` (already
required above) and uses the built-in `fetch`.

## CI

`.github/workflows/supabase-integration.yml` builds this stack and runs
`tests` (its own Vitest config, `tests/vitest.config.ts`) in a dedicated
workflow, separate from the Elixir `mix test`/`mix check` gate and from the
`@electric-sql/client` conformance check in `demos/electric/conformance`.
