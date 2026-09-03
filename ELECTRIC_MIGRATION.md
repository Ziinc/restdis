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

- **`where` clauses over a subquery** (`field IN (subquery)`,
  `ELECTRIC_PRD.md` Phase 6 item 1). Not supported; see the compatibility
  table.
As of this branch, gatekeeper mode, the `secret` query parameter, log
truncation (with a per-shape `retention` override on top of the tenant-level
`max_log_operations` default), and the `electric-schema` response header are
all implemented; see "Authentication" and the compatibility table below for
how each behaves.

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
| `secret` | Supported | Checked against the tenant's configured `shape_secret` (`RestdisElectric.subscribe/3`). A tenant with no `shape_secret` configured ignores the parameter, matching Electric's own open mode. A tenant with one configured requires `secret` to match exactly, or the request is a `401`. |
| `shape` | Supported | Names a server-configured shape when the tenant's `auth_mode` is `gatekeeper` (see "Authentication" below). Required in that mode; a `400` if missing or unknown. Meaningless, and never read, in open mode. |

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
| `@electric-sql/client`'s `ShapeStream`/`Shape` | `RestdisServer.HTTP.Electric` sends the `electric-schema` response header the client requires. |
| `@electric-sql/react`'s `useShape`, `@tanstack/electric-db-collection` | Not independently tested; both are built on `ShapeStream`. |

---

## Authentication

Electric ships no authentication and documents a "put a proxy in front of it"
pattern. Restdis authenticates directly:

- Send `authorization: Bearer <api-key>` on every `GET`/`DELETE /v1/shape`
  request. `RestdisServer.HTTP.Plug.Auth` resolves the key to a tenant via
  `RestdisServer.TenantConfig.lookup_by_api_key/1`; a missing or unknown key
  is a `401`.
- There is one API key per tenant relationship, managed through
  `restdis_repo`'s `api_keys` table (`RestdisRepo.ApiKeys`).
- Each tenant also has an `auth_mode`, `"gatekeeper"` (the default,
  `RestdisRepo.Tenants`) or `"open"`:
  - **Gatekeeper mode.** The client sends a `shape` name plus protocol
    parameters only. `table`, `where`, and `columns` are rejected with `400`
    if the client sends them. The server resolves the shape name against the
    tenant's `shape_definitions` rows (`RestdisRepo.ShapeDefinitions`,
    managed independently of the API key), which is where the table,
    `where`, `columns`, and `replica` live.
  - **Open mode.** The client supplies `table`/`where`/`columns` itself, as
    described throughout this document. A tenant may additionally set a
    `shape_secret`; when set, every request must also send a matching
    `secret` query parameter or the request is a `401`.

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
| `ELECTRIC_MAX_SHAPES` (or an equivalent flat limit) | Caps shape count for the one Electric instance | Per tenant `max_shapes` column on `tenants`, enforced by `RestdisElectric.Limits.check_shapes/1` and returned as a `429` |
| A per-instance limit on total log storage | Caps disk use for the one Electric instance | Per tenant `max_log_bytes` column on `tenants`, enforced by `RestdisElectric.Limits.check_log_bytes/3` and returned as a `429` |
| A per-instance limit on concurrent long-polling clients | Caps waiting connections for the one Electric instance | Per tenant `max_waiting_clients` column on `tenants`, enforced by `RestdisElectric.Limits.enter_wait/1` and returned as a `429` |
| Electric's unbounded log with compaction | Bounds how far back a client can resume | Per tenant `max_log_operations` column on `tenants` as the default, overridable per shape via a `retention` query parameter: `RestdisElectric.Log` truncates a shape's log to its effective retention (`RestdisElectric.Limits.effective_retention/2`), and a client that resumes at or below the truncated boundary gets a `409` (see "How we store the shape log" in `ELECTRIC_PRD.md`) |
| `ELECTRIC_PORT` / listen address | HTTP port Electric serves on | `HTTP_PORT` (`config/runtime.exs`), shared with every other Restdis HTTP endpoint |
| `ELECTRIC_LOG_LEVEL` / log format | Electric's own logging | Restdis's own logger config; `RESTDIS_JSON_LOGGER=true` switches to JSON output (`config/runtime.exs`) |
| A replication slot name/publication, one per Electric instance | Electric's logical replication bookmark | `WAL_SLOT_NAME` / `WAL_PUBLICATION_NAME` (`config/runtime.exs`), shared with cache invalidation across the whole cluster, not one slot per shape server |
| No tenant concept | Electric runs one instance per customer | Restdis's `tenants` table (`apps/restdis_repo`): one deployment, many tenants, one API key and one configuration row each |
| Metrics endpoint (Electric exposes its own) | Operational visibility | `GET /metrics` (Prometheus exposition, `RestdisServer.Metrics`); see the Grafana dashboard at `grafana/restdis-dashboard.json` |

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
