# Electric-SQL compat demo

`conformance/` is the full documented-behaviour conformance suite: the real,
published `@electric-sql/client` package (pinned in
`conformance/package.json`) exercised against a running Restdis instance,
covering every documented behaviour of Electric's TypeScript client that
Restdis implements - initial snapshot, live insert/update/delete, `where`
clause enter/exit transitions, `columns` projection, `replica=full`
old_value, resuming from a handle/offset, must-refetch (409 + rotation), the
`Shape` materialised-view API, gatekeeper mode, open mode's shared secret,
and documented error responses. See `prds/ELECTRIC_PRD.md` (Phase 6 item 7)
for what this suite is verifying.

This does not replace Restdis's own ExUnit suite (see
`apps/restdis_server/test/http/electric_test.exs` for status-code-level
coverage). It is the minimum needed to catch a real protocol regression that
only shows up against the actual client library, which `mix test` cannot
cover on its own.

## Running locally

Needs a running Restdis (with `wal_level=logical` Postgres) and its own
seed data:

```sh
mix ecto.create --quiet
mix ecto.migrate --quiet
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f demos/electric/conformance/seed.sql
mix run --no-halt &      # start Restdis

cd demos/electric/conformance
npm ci
RESTDIS_URL=http://localhost:4040 \
  RESTDIS_API_KEY=sk_conformance \
  CONFORMANCE_DATABASE_URL=postgres://postgres:postgres@localhost:5432/restdis_dev \
  npm test
```

A scenario for a documented behaviour that isn't implemented yet can be
marked `export const xfail = "reason"` in that scenario file; the runner
reports it as XFAIL rather than FAIL, and flags an unexpectedly-passing
xfail (XPASS) as a failure so a closed gap gets noticed.

## CI

`.github/workflows/conformance.yml` starts Postgres directly (needs a real
logical replication slot, which the workflow's `services:` block can't
configure), starts Restdis, seeds `conformance/seed.sql`, and runs
`npm test` in `demos/electric/conformance`. This check blocks merge on
failure, separate from the Elixir `mix test`/`mix check` gate and from the
Supabase-integration workflow.
