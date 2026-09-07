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

## CI

`.github/workflows/supabase-integration.yml` builds this stack and runs
`demo/tests` (its own Vitest config, `demo/tests/vitest.config.ts`) in a
dedicated workflow, separate from the Elixir `mix test`/`mix check` gate and
from the `@electric-sql/client` conformance check in `test/conformance`.
