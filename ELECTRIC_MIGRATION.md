# Migrating from Electric to Restdis

This document is for application developers who already have a working
Electric client and want to point it at Restdis instead. It also states,
precisely, which parts of the Electric HTTP protocol Restdis implements today,
and maps Electric's operational settings onto their Restdis equivalents for
whoever operates the deployment.

It describes this branch's code as it actually behaves, not the target state
in `ELECTRIC_PRD.md`. Where the two differ, this document says so.

---

## Terms used in this document

See "Terms used in this document" in `ELECTRIC_PRD.md`. This guide uses the
same vocabulary: shape, shape log, offset, handle, snapshot.

---

## The one-step migration

You do not run Electric and Restdis side by side. Point your existing client
at Restdis's base URL and let it resynchronise from the beginning:

1. Change the client's base URL (or `pgrst_base_url`-equivalent origin) from
   your Electric deployment to Restdis's `/v1/shape` endpoint.
2. Add an `authorization: Bearer <api-key>` header to every request (see
   "Authentication" below). This replaces whatever auth proxy you built in
   front of Electric.
3. Discard any handle and offset your client persisted from Electric. Restdis
   computes its own handles; an old Electric handle is meaningless here.
   Restart every client subscription from `offset=-1`.

Every Electric client library already implements the resynchronisation path,
because it is the same path they use to recover from a `409`. There is no
Restdis-specific migration code to write: you are just triggering the client's
existing "start over" behaviour once, deliberately.

The cost is one snapshot read per shape, exactly as if the shape had just been
created.

---

## What changes and what does not

**Does not change:**

- The wire protocol: query parameters, message shapes, and control messages
  are the same JSON your client already parses.
- `offset`, `handle`, `live`, `cursor` — the protocol parameters a client
  manages internally.
- `table`, `where`, `params`, `columns`, `replica` — the parameters that
  define a shape.
- Long-polling. It works the same way.

**Changes:**

- **Authentication.** Electric ships with none; you were expected to run your
  own authenticating proxy in front of it, which then set the shape
  definition on the client's behalf. Restdis authenticates every request
  itself with `RestdisServer.HTTP.Plug.Auth`, which reads
  `authorization: Bearer <api-key>` and resolves it to a tenant. You delete
  your proxy; you configure an API key instead.
- **Multi-tenancy.** Restdis separates tenants by API key and configuration.
  One Restdis deployment can serve many customers; Electric expects one
  deployment per customer.
- **Where a snapshot is read from.** Electric reads Postgres directly.
  Restdis reads through PostgREST by default (`pgrst_base_url` /
  `pgrst_api_key` on the tenant), or, for `log=changes_only`, directly through
  a configured `direct_pg_url`. Neither changes what the client receives.

**Not yet implemented on this branch** (see "Every entry below is verified
against the code," further down, for how this was checked):

- **Gatekeeper mode.** `ELECTRIC_PRD.md`'s "Authentication" section describes
  a per-tenant choice between "gatekeeper" (server names the shape, client
  sends only `offset`/`handle`/`live`/`cursor`) and "open" (client supplies
  `table`/`where`/`columns` itself, checked against a `queryable_columns`
  allow-list). As implemented today, every tenant runs in open mode: the
  client always supplies `table`, `where`, and `columns` directly
  (`RestdisElectric.Definition.new/2`), and there is no
  `queryable_columns` allow-list or gatekeeper shape registry anywhere in
  `restdis_repo` or `restdis_server`. If your migration plan assumed
  gatekeeper mode would stop clients from sending arbitrary filters, it is
  not there yet — every API key can currently define any shape over any
  table its tenant can read.
- **The `electric-schema` response header.** `ELECTRIC_PRD.md` documents this
  header as part of the response contract. `RestdisServer.HTTP.Electric`
  does not send it. The real, published `@electric-sql/client` (pinned
  version in `test/conformance/package.json`) refuses a response without it
  and raises `MissingHeadersError`, so **a client built on that library
  cannot complete a snapshot against this branch today.** This is the exact
  kind of regression the conformance suite (see below) exists to catch, and
  it is currently red because of this gap. Fixing it means changing
  `apps/restdis_server/lib/restdis_server/http/electric.ex`, which was left
  alone here because another change was in flight against that file at the
  time this guide was written.
- **Log truncation.** `ELECTRIC_PRD.md` Phase 6 item 5 (truncating each log to
  a configured length and returning `409` on resume below the retained
  window) has no implementation yet: no code path in `restdis_electric`
  truncates a log or checks a retention window.
- **`where` clauses over a subquery** (`field IN (subquery)`,
  `ELECTRIC_PRD.md` Phase 6 item 1). Not supported; see the compatibility
  table.

---

## Compatibility table

Every "Unsupported" entry below is backed by a `400` response at subscription
time (`GET /v1/shape`), verified either by reading
`apps/restdis_electric/lib/restdis_electric/eval.ex` and
`apps/restdis_electric/lib/restdis_electric/definition.ex` directly, or by an
existing test in `apps/restdis_electric/test/restdis_electric/eval_test.exs`
or `apps/restdis_server/test/http/electric_test.exs`. Restdis never silently
accepts a construct it does not evaluate correctly: `Eval.compile/2` rejects
anything outside the subset with `{:error, {:unsupported_where, _}}`, and
`RestdisServer.HTTP.Electric` turns that into a `400` before any log entry is
ever written for the shape.

### Protocol query parameters (`GET`/`DELETE /v1/shape`)

| Parameter | Support | Notes |
| --- | --- | --- |
| `table` | Supported | `schema.table` or bare `table` (defaults to `public`). Missing or empty is a `400`. |
| `offset` | Supported | `-1`, `now`, `0_inf`, or `{lsn}_{op}`. Anything else is a `400`. |
| `handle` | Supported | Required to resume; a mismatch with the server's computed handle triggers `409` + `must-refetch`. |
| `live` | Supported | Long-poll when true and nothing new is ready. |
| `cursor` | Supported | Carried into the response `etag` only; has no other server-side meaning, matching Electric. |
| `columns` | Supported | Comma-separated list; must cover the primary key or the request is a `400`; unknown columns are a `400`. |
| `where` | Supported for the documented subset | See below. Anything outside the subset is a `400`. |
| `params` | Supported | `params[1]=x` form or a JSON object body-equivalent string; binds `$1`-style placeholders in `where`. |
| `replica` | Supported | `default` or `full`; any other value is a `400`. |
| `live_sse` | Supported | Selects the Server-Sent Events transport instead of long-polling. |
| `log` | Supported | `full` or `changes_only`; `changes_only` without a tenant `direct_pg_url` is a `400`. |
| `secret` | **Not implemented — and not rejected** | Electric's documented open-mode auth parameter. Restdis reads no `secret` parameter at all: `RestdisServer.HTTP.Plug.Auth` only checks the `authorization` header. A request that includes `secret` is accepted and the parameter is silently ignored, which does **not** meet the "every unsupported entry is a `400`" bar. Tracked as a gap; see the note at the end of this table. |

### `where` clause constructs

Verified directly against `RestdisElectric.Eval.compile/2` and its `@comparison`/`@arithmetic`/`@bitwise`/`@array_ops`/`@logical`/`@functions`/`@is_tests` module attributes, and against the property/unit tests in `eval_test.exs`.

| Construct | Support |
| --- | --- |
| Comparison operators `= <> != < <= > >=` | Supported |
| Logical operators `AND OR NOT` | Supported |
| Arithmetic operators `+ - * / %` | Supported |
| Bitwise operators `& \| # << >>` | Supported |
| `LIKE` / `ILIKE` | Supported |
| Array operators `@> <@ &&` (array literal operand required on one side) | Supported |
| `IS NULL` / `IS NOT NULL` / `IS [NOT] TRUE` / `IS [NOT] FALSE` / `IS [NOT] UNKNOWN` | Supported |
| `IN` / `NOT IN` (literal list) | Supported |
| `BETWEEN` / `NOT BETWEEN` | Supported |
| `ANY` / `ALL` with a comparison operator | Supported |
| `lower`, `upper`, `coalesce`, `greatest`, `least` | Supported |
| `$1`-style placeholders bound from `params` | Supported |
| **`IN (subquery)`** (`ELECTRIC_PRD.md` Phase 6 item 1) | **Not supported** — rejected as an unsupported construct at `400`. Not implemented on this branch as of this writing. |
| JSONB operators, full-text search, geometric/network types, range operators, casts, volatile functions (`now()`, etc.) | Not supported, and never will be: `ELECTRIC_PRD.md` scopes Restdis to exactly Electric's documented subset on purpose, so a shape that works on Restdis and fails on Electric would make the migration one-way. |

### Client libraries

| Library | Status |
| --- | --- |
| `@electric-sql/client`'s `ShapeStream`/`Shape` | **Currently fails a full snapshot** against this branch: the client (pinned version 1.5.27 in `test/conformance/package.json`) requires an `electric-schema` response header that Restdis does not send. See "Not yet implemented on this branch" above. This is not a documentation gap — it is a real, reproducible failure, caught by `test/conformance/run.mjs`. |
| `@electric-sql/react`'s `useShape`, `@tanstack/electric-db-collection` | Not independently tested; both are built on `ShapeStream` and inherit the gap above. |

---

## Authentication

Electric ships no authentication and documents a "put a proxy in front of it"
pattern. Restdis authenticates directly:

- Send `authorization: Bearer <api-key>` on every `GET`/`DELETE /v1/shape`
  request. `RestdisServer.HTTP.Plug.Auth` resolves the key to a tenant via
  `RestdisServer.TenantConfig.lookup_by_api_key/1`; a missing or unknown key
  is a `401`.
- There is one API key per tenant relationship, managed through
  `restdis_repo`'s `api_keys` table (`RestdisRepo.ApiKeys`), not through a
  `secret` query parameter.
- As covered above, the "gatekeeper mode" that `ELECTRIC_PRD.md` describes
  (where the server, not the client, chooses the shape definition) is not
  implemented yet. Every authenticated request can define any shape over any
  table the tenant's Postgres connection can read.

---

## Operational settings: Electric to Restdis

`ELECTRIC_PRD.md`'s "boundary of compatibility" section is explicit that
Restdis reads no `ELECTRIC_*` environment variable and does not try to look
like Electric to an operator. This table exists so an operator migrating a
deployment (not a client) knows which Restdis setting serves the same
purpose. Restdis's names are taken directly from `config/runtime.exs` and the
tenant schema in `apps/restdis_repo/priv/repo/migrations`; Electric's names
are its documented environment variables.

| Electric setting | Purpose | Restdis equivalent |
| --- | --- | --- |
| `ELECTRIC_DATABASE_URL` | Postgres connection Electric replicates from | `DATABASE_URL` (the control-plane/replication connection, `config/runtime.exs`) plus, per tenant, `pgrst_base_url`/`pgrst_api_key` (snapshot reads) and optionally `direct_pg_url` (`log=changes_only` snapshots and direct-Postgres reads) on the `tenants` table |
| `ELECTRIC_STORAGE_DIR` | Where Electric persists shape logs on disk | No single directory: shape logs share Restdis's existing cache storage layer (CubDB today, per `ELECTRIC_PRD.md`'s "How we store the shape log"), rooted at `CACHE_DATA_DIR` |
| `ELECTRIC_MAX_SHAPES` (or an equivalent flat limit) | Caps shape count for the one Electric instance | Per tenant `max_shapes` column on `tenants` (added by the `AddShapeLimitsToTenants` migration; see the note below — this is in progress on this branch and enforcement was out of this document's scope) |
| A per-instance limit on total log storage | Caps disk use for the one Electric instance | Per tenant `max_log_bytes` column on `tenants` (same migration/caveat as above) |
| A per-instance limit on concurrent long-polling clients | Caps waiting connections for the one Electric instance | Per tenant `max_waiting_clients` column on `tenants` (same migration/caveat as above) |
| `ELECTRIC_PORT` / listen address | HTTP port Electric serves on | `HTTP_PORT` (`config/runtime.exs`), shared with every other Restdis HTTP endpoint |
| `ELECTRIC_LOG_LEVEL` / log format | Electric's own logging | Restdis's own logger config; `RESTDIS_JSON_LOGGER=true` switches to JSON output (`config/runtime.exs`) |
| A replication slot name/publication, one per Electric instance | Electric's logical replication bookmark | `WAL_SLOT_NAME` / `WAL_PUBLICATION_NAME` (`config/runtime.exs`), shared with cache invalidation across the whole cluster, not one slot per shape server |
| No tenant concept | Electric runs one instance per customer | Restdis's `tenants` table (`apps/restdis_repo`): one deployment, many tenants, one API key and one configuration row each |
| Metrics endpoint (Electric exposes its own) | Operational visibility | `GET /metrics` (Prometheus exposition, `RestdisServer.Metrics`); see the Grafana dashboard at `grafana/restdis-dashboard.json` |

**Caveat on the three `max_*` tenant columns:** at the time this document was
written, another change on this branch was adding the migration that creates
`max_shapes`, `max_log_bytes`, and `max_waiting_clients` on `tenants`, plus
the `429` enforcement `ELECTRIC_PRD.md` Phase 6 item 3 describes. The columns
may exist without enforcement wired up yet, depending on exactly when you
read this against the branch. Check
`apps/restdis_electric/lib/restdis_electric/limits.ex` (if present) before
relying on this row.

---

## The conformance suite

`test/conformance/` runs the real, published `@electric-sql/client` (pinned
in `test/conformance/package.json`, not a `^`-range) against a running
Restdis instance: it subscribes to a snapshot, asserts the seeded row is
there, writes a new row directly to Postgres, and asserts the live update
reaches the client. `.github/workflows/conformance.yml` runs it in CI on
every push and pull request and fails the build if it fails — see that
workflow and `test/conformance/run.mjs` for the exact steps.

As of this writing, that suite fails, for the real reason described above
(`electric-schema` header). That is the suite doing its job: it is supposed
to fail when the client and the server disagree about the protocol, and
right now they do.
