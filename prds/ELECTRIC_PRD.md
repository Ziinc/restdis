# Electric-compatible shape API

## Terms used in this document

- **Electric** — ElectricSQL, the sync engine whose HTTP protocol this app implements.
- **Shape** — a table (or a filtered subset of it) that a client subscribes to and receives as an ordered log of changes.
- **Handle** — the opaque identifier a client holds for a shape, computed from `(tenant_id, shape definition)`.
- **Log** — the append-only, offset-addressed sequence of change messages for a shape.

## Problem

Electric keeps a copy of Postgres data up to date on client devices: it reads the WAL through one replication slot, splits the stream into per-client shapes, and serves each as a shape log over HTTP. Its value lives in the client libraries (`@electric-sql/client`, `@electric-sql/react`, `@tanstack/electric-db-collection`, `electric_client`, `y-electric`); the server behind them is replaceable.

Restdis already has most of the expensive parts of this design: a WAL reader with one replication slot per cluster and AZ fan-out, a three-layer cache with cross-node replication, a reverse index that solves the same row-routing problem as Electric's shape filter, and tenant/API-key infrastructure. `restdis_electric` adds the two missing pieces — the ordered shape log and the `GET /v1/shape` HTTP protocol — so an application built against an Electric client library works against Restdis after changing one base URL.

Compatibility is scoped to clients only: an app using `@electric-sql/client@^1`, `@electric-sql/react@^1`, or `@tanstack/electric-db-collection` works unmodified after pointing its `url` at Restdis. Restdis targets the Electric 1.x protocol as a fixed specification; it does not track Electric's ongoing development. A tenant migrating off Electric points its clients at Restdis, lets them resynchronize from `offset=-1` (the same `409`-triggered path every Electric client already implements), and retires the old deployment — the two are not run side by side.

## Architecture

`restdis_electric` is a standalone umbrella app (namespace `RestdisElectric`) depending only on `restdis` (the cache/WAL library). `restdis_buster` pushes decoded WAL changes into it; `restdis_server` pulls from it over HTTP. Neither of those appears in its dependency list, and a `check.boundary` guard in both `apps/restdis/mix.exs` and `restdis_electric` enforces this in both directions.

Public surface:

- `RestdisElectric` — turns a shape definition into a handle, reads a range of the log, awaits new data, deletes a shape. Returns domain values (`{:ok, messages, offset}`, `{:error, :must_refetch, new_handle}`, `{:error, {:unsupported_where, expr}}`), never an HTTP status or a `Plug.Conn`.
- `RestdisElectric.Definition` — builds and validates a shape definition.
- `RestdisElectric.WAL` — receives decoded WAL changes from `restdis_buster` and reports back which LSN it has durably written.

`restdis_server` owns the HTTP contract: `GET` and `DELETE /v1/shape` on `RestdisServer.HTTP.Endpoint`, behind the same `RestdisServer.HTTP.Plug.Auth` tenant-resolution used by `/pgrst/query`, translated by a single adapter module (`RestdisServer.HTTP.Electric`) that is the only place that knows Electric's headers and status codes.

## Protocol

`GET /v1/shape` query parameters:

| Parameter | Behavior |
| --- | --- |
| `table` | Table name, optionally schema-qualified. Required unless resuming with a `handle`. |
| `offset` | `-1` starts from the beginning and triggers a snapshot; `0_inf` is the end of the snapshot; `{lsn}_{op_offset}` resumes at a position; `now` skips all history. |
| `handle` | Identifies the shape; required whenever `offset` is not `-1`. |
| `live` | Holds the request open (long-poll) until new data arrives. |
| `cursor` | Defeats stale caching on live reconnect. |
| `columns` | Column projection; must include the primary key. |
| `where` | Postgres boolean expression filtering rows (subset described below). |
| `params` | Values for `$1`-style placeholders in `where`. |
| `replica` | `default` or `full`; controls whether update/delete messages carry the full old row. |
| `live_sse` | Server-Sent Events instead of long-polling. |
| `log` | `full` (snapshot then changes) or `changes_only` (changes only, requires a direct Postgres pool). |
| `secret` | Shared-secret gate for direct (non-gatekeeper) access. |

Response headers: `electric-handle`, `electric-offset`, `electric-up-to-date`, `electric-schema`, `cache-control`, `etag`, and `location` on a `409`.

Response body is a JSON array of messages: change messages (`{key, value, old_value?, headers: {operation, lsn?, op_position?, handle?}}`) and control messages (`{headers: {control: "up-to-date" | "must-refetch"}}`; `changes_only` mode also emits a `snapshot-end` message carrying the Postgres snapshot descriptor).

Status codes: `200` (data, including a timed-out live request whose body holds only `up-to-date`), `400` (invalid shape definition — unknown table, unsupported `where`, or a column list missing the primary key), `409` (handle no longer valid; `location` carries a fresh handle), `429` (tenant hit a configured limit).

`DELETE /v1/shape` is available when the tenant's `allow_shape_deletion` setting is on; it flushes the shape's log via the same path as a `409`.

## Storage

The shape log is a purpose-built append-only store (`RestdisElectric.Log`), not CubDB, mapped onto the existing cache layers:

1. **ETS** — the open (currently-being-written) chunk, plus per-shape metadata (offset, handle, schema, waiting clients). Live long-polls read only from here.
2. **NVMe files** — closed chunks (immutable once written) plus a sparse chunk index. Both only grow at the end, so readers never block the writer. CubDB still holds shape *metadata* (small, needs transactions), not log bodies.
3. **Origin** — the initial snapshot is read from PostgREST (or the tenant's configured read replica) a page at a time, through `Restdis.Cache.Origin`.

Closed chunks are immutable and replicate to other nodes the same way durable cache entries do, so any node in the region can serve a resume request.

Retention is a configurable number of recent operations per shape (tenant-level default, overridable per shape). Operations outside the window are deleted; a client resuming below the window gets `409`/`must-refetch`. This differs from Electric's unbounded-log-plus-compaction design on purpose: truncation trades away arbitrarily-old resume in exchange for a hard disk-use bound and much simpler code. Both designs are correct from a client's point of view, since the only observable is whether the offset it holds still exists.

Durability rule: an LSN is confirmed back to Postgres only after every active shape has durably written every change up to that LSN, not merely dispatched it.

## Snapshot/log consistency

Because the origin is PostgREST (no transaction visibility), Restdis uses **LSN bracketing with idempotent operations** instead of Electric's `pg_current_snapshot()` approach: record the current WAL position `L0` and start buffering matching changes; read the PostgREST snapshot page by page into the log as inserts, up to `0_inf`; then replay the buffered changes from `L0` onward. Any transaction that committed between `L0` and the snapshot read is duplicated (once from the snapshot, once from replay), which is safe because every operation is keyed by row and idempotent (`insert` upserts, `delete` of an absent row is a no-op).

When a tenant has a direct Postgres pool configured, `RestdisElectric.Snapshotter` uses Electric's exact transaction-snapshot method instead, producing fewer duplicates; this is required for `log=changes_only`, since only the direct path can produce the snapshot descriptor the client needs to deduplicate. `log=changes_only` returns `400` without a direct pool.

## `where` clause evaluation

Clauses are parsed with `datafusion-sqlparser-rs` (via Rustler, `PostgreSqlDialect`) and evaluated in-process against every row from the WAL — never pushed down to Postgres. Supported: comparison, logical, arithmetic and bitwise operators; `LIKE`/`ILIKE`; array operators `@>`, `<@`, `&&`; null/boolean tests; `IN`/`NOT IN`; `BETWEEN`; `ANY`/`ALL`; and `lower`, `upper`, `coalesce`, `greatest`, `least`. Not supported (matching Electric): JSONB operators, full-text search, geometric/network types, range operators, and volatile functions (`now()`, `count()`, etc.). Anything outside the subset is rejected with `400` at subscribe time, naming the unsupported part.

Rows that start or stop matching a filter on an update are handled explicitly: a newly-matching row is emitted as an `insert` (the client has never seen it); a no-longer-matching row is emitted as a `delete` (the client must drop it even though the row still exists). This requires `REPLICA IDENTITY FULL` on tables read by shapes, since the previous row's full contents are needed to evaluate the filter against the pre-update state.

Subqueries are supported for the bare form (`field IN (subquery)` / `NOT IN (subquery)` as the shape's entire filter), and for that form combined with exactly one subquery-free predicate over a top-level `AND`/`OR`: `RestdisElectric.SubqueryTracker` incrementally tracks the subquery's table and emits `insert`/`delete` when a value's membership flips, re-checking the rest of the clause against the affected row when combined. More than one subquery in a clause, or a subquery under a top-level `NOT` alongside another predicate, returns `400`.

## Fan-out

`RestdisElectric.Filter` indexes shapes by the constant in `field = constant` clauses, the same technique Electric uses to keep per-row filter evaluation cost independent of shape count. Restdis adds two things Electric (a single instance) cannot have: tenant-to-node routing filters shapes before evaluation even starts, and per-AZ WAL fan-out already bounds cross-AZ traffic to one message per AZ per change.

Live long-poll requests for the same `(tenant, handle, offset)` are collapsed into one waiting set in ETS server-side (not via a CDN, as Electric requires): one log append wakes every waiter. Resume reads of settled offsets hit already-cross-node-replicated closed chunks. Correct `cache-control`/`etag` headers are still sent, so an optional CDN in front of Restdis still collapses requests, but it is not required to reach scale.

## Authentication

Electric ships no authentication; every deployment needs an authenticating proxy in front of it. Restdis has that already via `RestdisServer.HTTP.Plug.Auth` and per-tenant config, exposed as two modes, chosen per tenant via `auth_mode`:

- **Gatekeeper mode** (default) — tenant config names each shape definition; the client sends only a shape name and protocol parameters (`offset`, `handle`, `live`, `cursor`); `table`/`where`/`columns` sent by the client are rejected.
- **Open mode** — the client supplies the full shape definition, constrained by a `queryable_columns` allow-list and an optional shared secret (`secret` parameter).

Both modes produce identical logs.

## Reasons for `409`

| Cause | Source |
| --- | --- |
| Replication slot recreated/invalidated | Slot config in `restdis_buster`; invalidates every shape. |
| Table schema changed | The `DROP TABLE` DDL event trigger, plus a periodic (60s) schema check, since some DDL produces no WAL notification. |
| Shape evicted at a tenant's `max_shapes` limit | `RestdisElectric.ShapeRegistry.least_recently_used/1` evicts the least-recently-accessed idle shape; if every shape is busy (blocked in a live long-poll), the subscribe is rejected with `429` instead. |
| Client resumed below the retained window | Log truncation. |
| `DELETE /v1/shape` called | Only when `allow_shape_deletion` is on. |
| Postgres timeline/system identifier changed | Checked on slot (re)connect. |

## Scope boundary

Restdis does not attempt operational compatibility with Electric: no `ELECTRIC_*` environment variables, no Electric storage layout — configuration, storage, and `/metrics` are Restdis's own. Compatibility is client-protocol-only.

Not implemented, matching Electric: writes/conflict resolution/CRDTs (writes still go to PostgREST), shapes spanning multiple tables, changing a shape definition in place (a different definition gets a different handle), Electric's pre-2024 protocol/DDLX/client-side SQLite storage, server-side PGlite or `y-electric` support (client-side concerns; work if the log is correct), and origins other than Postgres. `where` support is capped at exactly Electric's documented subset — never wider — because a shape that works on Restdis and fails on Electric would make migration one-way.

## Compatibility summary

| Capability | Restdis |
| --- | --- |
| `ShapeStream`/`Shape` (`@electric-sql/client`), `useShape` (`@electric-sql/react`), `@tanstack/electric-db-collection`, `y-electric`, `electric_client` (Hex) | Supported; client changes only its URL. |
| Live updates (long-poll and SSE) | Supported. |
| `where` in Electric's documented subset, `columns`, `replica`, `params` | Supported. |
| `where` with subqueries | Supported for the bare/combined forms described above; other shapes return `400`. |
| `log=changes_only` | Supported only with a tenant direct-Postgres pool configured; `400` otherwise. |
| Multi-table shapes, in-place shape redefinition, writes/conflict resolution | Not supported (neither does Electric). |
| Multi-tenant on one deployment, built-in auth | Supported (Electric has neither). |
| Requires a CDN to scale | Not required (Electric does). |
| Replication slots | One per cluster, shared with cache invalidation (Electric: one per instance). |
