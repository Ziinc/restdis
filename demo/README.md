# Supabase demo stack

Runs Restdis (built from the root `Dockerfile`) against a real PostgREST and
GoTrue, standing in for a self-hosted Supabase project. Verifies the
integration points described in `SUPABASE_INTEGRATION_PRD.md` against real
origins instead of stubs. Separate from the root `docker-compose.yml`, which
is for local development against bare Postgres.

## Running locally

```sh
cd demo
docker compose up -d --build
cd tests
npm install
RESTDIS_URL=http://localhost:4041 npm test
docker compose -f ../docker-compose.yml down -v
```

## Ports

| Service  | Port (host) |
| -------- | ----------- |
| restdis  | 4041 (HTTP), 6381 (RESP) |
| db       | 5433        |
| rest     | 3000        |
| auth     | 9999        |

These are offset from the root `docker-compose.yml`'s ports (4040, 6380,
5432) so both stacks can run side by side.

## supabase-js wrapper

`client/restdis-supabase.mjs` wraps the real `@supabase/supabase-js` client.
`.from(table).select(columns)` behaves exactly like the real client normally
would. Add `{ cache: '30s' }` to `select()`'s options and the request is
rerouted through Restdis's `/pgrst/query` cache instead of going straight to
PostgREST - the point being to show the interception happening from an
application's normal call shape, not a bespoke test client.

```sh
cd demo/client
npm install
node demo.mjs
```

Not shipped code - it's the minimum needed to demonstrate the cache option
against a real client for the demo script and screen recording below.

## Screen-recording walkthrough

`scripts/demo.sh` is a narrated, pause-between-steps script for recording a
demo: origin PostgREST query → cache miss through Restdis → cache hit →
direct write to Postgres → WAL-driven cache bust → GoTrue reachability.

```sh
cd demo
./scripts/demo.sh              # brings the stack up, then walks through it,
                                # pausing for enter between steps
./scripts/demo.sh --no-up      # stack already running, skip straight to the walkthrough
DEMO_AUTOPLAY=1 ./scripts/demo.sh   # no keypresses; sleeps between steps instead
```

Requires `curl`, `psql`, and `docker compose` on `PATH`.

## CI

`.github/workflows/supabase-integration.yml` builds this stack and runs
`demo/tests` (its own Vitest config, `demo/tests/vitest.config.ts`) in a
dedicated workflow, separate from the Elixir `mix test`/`mix check` gate and
from the `@electric-sql/client` conformance check in `test/conformance`.
