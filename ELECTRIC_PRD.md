# RFC: Electric-Compatible Shape API on Restdis

---

## Problem

ElectricSQL is a read-path sync engine for Postgres: it tails one logical replication slot, filters the stream into per-client subsets called *shapes*, and serves each shape as an append-only, offset-addressed log over a cacheable HTTP API. Its client ecosystem — `@electric-sql/client`, `@electric-sql/react`, `@tanstack/electric-db-collection`, `electric_client` (Hex), `y-electric` — is the practical reason teams adopt it. The sync service itself is a commodity; the integration surface is not.

Restdis already owns every expensive piece of that architecture except the shape log:

- a cluster-wide WAL tailer (`restdis_buster`) consuming exactly one replication slot, with `syn`-based singleton failover, per-AZ fan-out, and LSN resume;
- a per-tenant three-layer cache (ETS → CubDB → PostgREST origin) with global disk replication for `persist` entries;
- a reverse index mapping `(table, primary_key) -> cache_keys`, which is structurally the same routing problem Electric solves with its shape filter;
- tenant config, API-key auth, consistent-hash tenant routing, and Prometheus/OTel instrumentation.

What Restdis lacks is the **ordered, resumable, offset-addressed log** that Electric clients speak, and the **HTTP protocol** that carries it.

The proposal: expose an `Electric.Shapes`-compatible `GET /v1/shape` endpoint from `restdis_server`, backed by a new `restdis_shape` bounded context, so that **any existing Electric client integration works unmodified against Restdis by changing one base URL** — while the log is served out of Restdis's multi-layer cache instead of Electric's single-instance file store plus an external CDN.

### Who is asking for this

- **Platform customers already running Electric** who want sync without operating a second stateful service, a second replication slot, and a CDN contract.
- **Existing Restdis tenants** who want live-updating reads (dashboards, collaborative UIs, agent state) and today poll `PGRST.QUERY` on a timer.
- **Teams evaluating Electric** who are blocked on it being a separate, single-instance, non-multi-tenant service with its own auth-proxy requirement.

### Why this matters

Electric's own framing is that the hard, don't-DIY parts of sync are partial replication, fan-out, and delivery. Restdis already solves fan-out and delivery for the request/response path and already pays the WAL-ingestion cost. Adding the shape log reuses that investment across a second, higher-value access pattern instead of standing up parallel infrastructure. And because the client protocol is a documented HTTP contract, compatibility is *testable*: the Electric TypeScript client's own conformance expectations become our acceptance criteria.

---

## Background

### Non-negotiable: the compatibility contract

This RFC's success criterion is **drop-in replacement**, defined precisely as:

> An application using `@electric-sql/client@^1`, `@electric-sql/react@^1`, or `@tanstack/electric-db-collection` continues to work correctly after changing only the `url` option (and, where used, the gatekeeper proxy target) to point at Restdis. No client code change, no dependency change, no fork.

Everything in Scope below is subordinate to that. Where Restdis's internals differ from Electric's, the difference must be invisible at the protocol boundary or explicitly documented as an unsupported shape definition that fails **at subscription time with a 400**, never as silent divergence in the log.

### Protocol surface to implement

`GET /v1/shape` query parameters:

| Param | Semantics | Phase |
| --- | --- | --- |
| `table` | Root table, optionally schema-qualified. Required unless resuming with a handle. | 1 |
| `offset` | `-1` (from start, triggers snapshot), `0_inf` (end of snapshot), `{lsn}_{op_offset}` (resume), `now` (skip history). | 1 |
| `handle` | Shape handle. Required when `offset > -1`. | 1 |
| `live` | Long-poll for new data. | 2 |
| `cursor` | Cache-busting cursor for live reconnects. | 2 |
| `columns` | Projection. Must include the primary key. | 2 |
| `where` | Postgres SQL boolean expression, with `params` / `$1` placeholders. | 3 |
| `params` | Positional parameter values for `where`. | 3 |
| `replica` | `default` or `full` — whether update/delete carry the full old row. | 3 |
| `live_sse` | Server-Sent Events transport instead of long-poll. | 4 |
| `log` | `full` (snapshot then changes) or `changes_only`. | 5 |
| `secret` | Shared secret gating direct access. | 2 |

Response headers: `electric-handle`, `electric-offset`, `electric-up-to-date`, `electric-schema`, `cache-control`, `etag`, and `location` on 409.

Body: a JSON array of messages.

- `ChangeMessage`: `{ key, value, old_value?, headers: { operation: "insert"|"update"|"delete", lsn?, op_position?, handle? } }`
- `ControlMessage`: `{ headers: { control: "up-to-date" | "must-refetch" } }`, plus `snapshot-end` carrying the Postgres snapshot descriptor in `changes_only` mode.

Status codes: `200` (data, or live timeout with only an `up-to-date` control message), `400` (invalid shape definition — unparseable or unsupported `where`, unknown table, projection missing the PK), `409` (`must-refetch`; handle invalidated, with `location` pointing at a fresh handle), `429` (per-tenant limits).

Also: `DELETE /v1/shape` behind an `allow_shape_deletion` flag, mirroring the existing per-tenant flush path.

### Architecture: mapping Electric concepts onto Restdis contexts

| Electric component | Restdis equivalent | Delta to build |
| --- | --- | --- |
| `Electric.Postgres.ReplicationClient` | `RestdisBuster.Tailer` + `Wal.PGOutput` | Require `REPLICA IDENTITY FULL` on shape-backing tables; carry full old/new tuples through `Wal.Event`. |
| `ShapeLogCollector` | `RestdisBuster.Dispatcher` | New dispatch target alongside invalidate/refresh: `:shape_append`. |
| `Electric.Shapes.Consumer` (per-shape GenServer) | new `RestdisShape.Consumer` | New. One per active shape, under the tenant aggregate. |
| `Electric.Shapes.Filter` (hash-indexed routing) | `Restdis.Cache.ReverseIndex` (same shape of problem, different key) | New `RestdisShape.Filter`: `(table, column, constant) -> MapSet(shape_handle)`. |
| `PureFileStorage` (log + sparse offset index) | `Restdis.Cache.DiskCache` (CubDB) + ETS | New `RestdisShape.Log` — append-only, chunked, sparse-indexed. See "Storage" below. |
| Snapshot via read-only txn + `pg_current_snapshot()` | `Restdis.Cache.Origin.PostgREST` | New snapshotter; consistency handled by LSN-buffer + idempotent apply (below). |
| CDN request collapsing | Restdis multi-layer cache + per-AZ `syn` fan-out + global `persist` replication | Serve the collapsing role in-process; remain CDN-compatible on top. |
| Auth gatekeeper proxy (user-built) | `RestdisServer.HTTP.Plug.Auth` + tenant config | Native. Shape definitions bound server-side per API key. |

New umbrella child: **`restdis_shape`** — the shape bounded context. It owns shape definitions, handles, the log, the filter index, and consumers. Per `AGENT.md`, cross-context calls go through public APIs only; `restdis_shape` depends on `restdis` (cache/storage primitives) and is driven by `restdis_buster` via the dispatcher, and read by `restdis_server` via a public API. `restdis_shape` must not reach into `RestdisBuster` internals, and `restdis` (the standalone library) must not reference it at all.

### Storage: the shape log on Restdis's layers

Electric's v1.1 lesson is explicit: a general-purpose KV store (CubDB) was the wrong substrate for an append-only log, and replacing it with a purpose-built chunked file store bought ~102x writes and ~73x reads on SSD, plus lock-free readers, read replicas, and zero-downtime deploys. Restdis's Phase 1 PRD already flags CubDB write throughput as unvalidated.

We do not repeat Electric's mistake. `RestdisShape.Log` is a purpose-built append-only store from the start, mapped onto the three layers:

1. **Layer 1 (ETS, hot).** The open (unfinalized) chunk and shape metadata: current offset, handle, schema, subscriber set. Live long-polls are served entirely from here — a live reader never touches disk.
2. **Layer 2 (append-only chunk files on NVMe, durable).** Finalized immutable chunks of pre-serialized JSON lines plus a sparse offset index appended only at chunk finalization. Readers binary-search the sparse index, then scan the chunk. Append-only + append-only index ⇒ readers and the single writer never contend, no locks. CubDB continues to hold shape *metadata* (definition, handle, last offset, snapshot LSN), not log bodies — metadata is small, transactional, and already replicated. CubDB is slated for replacement in Restdis generally; confining shapes to metadata keeps the shape context off the critical path of that migration, and `RestdisShape.Log` should reach it only through the `Restdis.Cache` public API so the swap is a one-context change.
3. **Layer 3 (origin).** PostgREST (or the tenant's configured read replica) for the initial snapshot, paginated, reusing `Restdis.Cache.Origin` and the existing per-tenant API key.

Finalized chunks are immutable and therefore replicable: the existing global `persist` replication path can push hot shape chunks to peer nodes, which is what lets any node in the region serve a resume request without a cross-node hop.

**Durability rule (inherited from Electric, and required for correctness):** never `fsync` per write; instead only advance the replication slot's confirmed LSN to a position durably persisted in the shape logs. A crash replays from the last persisted LSN. This constrains `RestdisBuster.Infra.LSNStore` — today it confirms on dispatch; with shapes it must confirm on *persist acknowledgement from every active shape consumer*, or the log can lose acknowledged changes.

### Snapshot/log consistency without a Postgres snapshot descriptor

This is the sharpest architectural difference, and it needs to be right.

Electric takes its initial snapshot with a direct SQL query in a read-only transaction, records `pg_current_snapshot()` (`xmin`, `xmax`, `xip_list`), and skips any buffered replication transaction whose `xid` satisfies `xmin < xid < xmax and xid not in xip_list` (already reflected in the snapshot). Restdis's Layer 3 is PostgREST, which cannot return a snapshot descriptor, and Restdis's tailer already has the WAL stream but not per-shape xids.

Restdis uses **LSN-bracketing plus idempotent apply**:

1. Record `L0` = the tailer's current confirmed LSN, and begin buffering all matching WAL events for the shape from `L0`.
2. Take the snapshot from PostgREST (paginated), writing each row as an `insert` operation into the log up to `0_inf`.
3. Replay the buffer from `L0` forward, appending to the log after `0_inf`.

Any transaction that committed between `L0` and the snapshot read appears **twice**: once in the snapshot, once in the replay. This is safe because the shape log's materialization semantics are idempotent per key — `insert` is a set, `update` is a merge, `delete` is a remove, all keyed by row key. A duplicate insert of a row already present converges to the same state; a delete of an absent row is a no-op. Electric relies on exactly this property for its own `changes_only` subset snapshots, where inserts are applied as upserts to tolerate overlap. The compatibility requirement is therefore narrow and satisfiable: **the log must never omit an operation, and every operation must be idempotent under the client's documented apply rules.** Restdis's scheme guarantees both.

Cost and trade-off, stated plainly:

- **Cost:** a bounded window of duplicated operations at the snapshot boundary — bytes, not correctness. Bounded by write volume during the snapshot fetch.
- **Trade-off vs. Electric:** we give up exact-once at the boundary and gain the ability to snapshot through PostgREST — which means the snapshot inherits PostgREST's RLS enforcement, the tenant's read-replica routing, and Restdis's existing origin plumbing, instead of requiring a second privileged direct-Postgres pool.
- **Escape hatch:** where a tenant has a direct Postgres pool configured, `RestdisShape.Snapshotter` may use the exact `pg_current_snapshot()` xid-dedup path instead. Same log output, fewer duplicates. Phase 5.
- **Client-visible:** none for `log=full`. For `log=changes_only` (Phase 5), Electric exposes the snapshot descriptor to the client in the `snapshot-end` control message so the client performs the skip. Without a descriptor we cannot populate that field, so `changes_only` is gated on the direct-Postgres path and returns 400 otherwise.

### Where-clause evaluation

Electric ships its own Postgres expression parser and evaluator in Elixir and evaluates the predicate against each replication row in-process. Restdis must do the same: asking Postgres or PostgREST to evaluate the predicate per row per shape defeats the point.

Compatibility strategy, ordered by risk:

1. **Parse with [`datafusion-sqlparser-rs`](https://github.com/apache/datafusion-sqlparser-rs) via Rustler**, not a hand-rolled Elixir parser. Its `PostgreSqlDialect` covers the whole expression grammar we accept, it is fast enough to be irrelevant on a subscription-time path, and it is a safe-Rust library — a malformed expression returns a parse error rather than risking the memory-unsafety surface a C parser NIF would bring into the VM. It parses a *superset* of what we evaluate, which is the right direction: the accepted-construct boundary is enforced by our own AST walk, not by whatever the parser happens to reject.
2. **Evaluate exactly the documented subset**, matching Electric's `known_functions.ex`: comparison, logical, arithmetic, bitwise, `LIKE`/`ILIKE`, array operators (`@>`, `<@`, `&&`), null/boolean tests, `IN`/`NOT IN`, `BETWEEN`, `ANY`/`ALL`, and `lower`/`upper`/`coalesce`/`greatest`/`least`. Unsupported, same as Electric: JSONB operators, full-text search, geometric, network-address, range operators, and non-deterministic functions (`now()`, `count()`).
3. **Fail closed at subscription.** Anything outside the subset returns `400` with the offending expression named. Never accept a shape we will silently mis-filter — a wrong filter is a data leak.
4. **Subqueries (`field IN (subquery)`) are Phase 6, not MVP.** They require cross-table dependency tracking so rows move in and out when the subquery result changes. Until then, they 400.

**Move-in / move-out** is mandatory from Phase 3, not an optimization: a row that starts matching is emitted as an `insert` (the client has never seen it); a row that stops matching is emitted as a `delete` (the client must drop it) even though the row still exists. This is why `REPLICA IDENTITY FULL` is required — the old row values must be present to evaluate the predicate against the pre-image.

### Fan-out: where Restdis diverges by design

Electric evaluates every shape's where clause against every row, and optimizes with a hash index over the constant in `field = constant`-shaped clauses, keeping throughput flat (~5,000 changes/sec) regardless of shape count; non-optimized clauses degrade roughly inversely with shape count.

`RestdisShape.Filter` implements the same idea, and Restdis's reverse index is the existing proof the team can build it. Two Restdis-native advantages:

- **Tenant sharding is a first filter.** The consistent hash ring already partitions tenants across nodes, so a node only evaluates shapes for tenants it owns. Electric's single-instance model has no equivalent.
- **Per-AZ `syn` fan-out already bounds broadcast volume**, so cross-AZ traffic stays at one message per AZ per event regardless of how many shapes exist.

And the caching divergence, which is the whole thesis:

Electric's scaling story requires a CDN performing request collapsing — a million long-polls become one origin request. Restdis's multi-layer cache plays that role in-process: identical live requests for `(tenant, handle, offset)` are collapsed into one waiter set in ETS, served from the open chunk on append; identical resume requests hit finalized immutable chunks in L1/L2, globally replicated. **The CDN becomes an optimization, not a prerequisite.** We still emit correct `cache-control`/`etag` on immutable offsets so a CDN in front collapses too — Electric-compatible, but not Electric-dependent. This matters for self-hosted and single-region deployments, where Electric's architecture is at its weakest.

### Auth: gatekeeper by default

Electric ships no auth and expects every production deployment to build a proxy that authenticates the request and sets the shape definition server-side, restricting the client to protocol-only params (`offset`, `handle`, `live`, `cursor`).

Restdis has this already: `RestdisServer.HTTP.Plug.Auth` resolves a tenant from a Supabase API key, and tenant config is per-tenant. The Electric endpoint therefore ships with two modes:

- **Gatekeeper mode (default).** Shape definitions are named in tenant config; the client passes a shape *name* plus protocol params. `table`/`where`/`columns` from the client are rejected. This is the pattern Electric documents but makes you build.
- **Open mode.** Client-supplied shape definitions, bounded by a `queryable_columns` allow-list and an optional shared `secret`, for parity with a bare Electric deployment behind someone else's proxy.

Both modes serve byte-identical logs. Gatekeeper mode is what makes the endpoint safe to expose multi-tenant, which Electric cannot do at all.

### Handles, offsets, and cache keys

- **Handle.** Electric's handle is a deterministic hash of the shape definition, formatted `{hash}-{epoch_ms}`, treated as opaque by clients. Restdis must keep that format. Note: **do not use `:erlang.phash2/1` here.** `Restdis.Cache.Key` uses `phash2` for cache keys, which is fine for process-local caching, but a shape handle is persisted to disk and held by clients across deploys and OTP upgrades. Handles use a truncated SHA-256 over the canonicalized shape definition. Identical definitions from different tenants must *not* collide into one log — the handle is computed per `(tenant_id, definition)`, with the tenant component never exposed to the client.
- **Offset.** `{lsn}_{op_offset}` where `lsn` is the integer Postgres LSN and `op_offset` is the operation's position within its transaction. `RestdisBuster.Infra.LSN` already models this.
- **Cache key.** Add a `:shape` scope to `Restdis.Cache.Key` so shape chunks live in the same addressing space as PGRST entries and inherit per-tenant caps, metrics, and flush.

### 409 / must-refetch triggers

Every path that discards a shape log must surface as `409` with a `location` header carrying a fresh handle, because that is the only signal Electric clients understand for "start over":

| Trigger | Restdis source |
| --- | --- |
| Replication slot recreated or invalidated | `RestdisBuster` slot config; slot invalidation purges all shapes. |
| Schema change on the shape's table | Existing DDL event trigger (`DROP TABLE` invalidation) plus a periodic reconciliation of cached table metadata, matching Electric's 60s check for changes that emit no relation message. |
| Shape evicted under per-tenant caps | Existing LRU eviction. **Must be wired to 409, not silent eviction** — a silently dropped shape becomes a permanently stale client. |
| Explicit `DELETE /v1/shape` | New, behind `allow_shape_deletion`. |
| Postgres timeline / system identifier change | `RestdisBuster` slot config check on connect. |

### Compatibility boundary: client-side only

Compatibility stops at the HTTP protocol. Restdis is configured, deployed, and operated as Restdis: its own environment variables, its own storage layout, its own `/metrics` endpoint, its own tenant config. No `ELECTRIC_*` environment variable is read, and no attempt is made to look like an Electric deployment to an operator.

The reason is that server-side compatibility buys nothing and costs a permanent constraint. The people we are unblocking are application developers with Electric client code they do not want to rewrite; the operator is deploying Restdis deliberately. Honoring `ELECTRIC_STORAGE_DIR` or `ELECTRIC_MAX_SHAPES` would pin Restdis's internals to Electric's operational model — one instance, one storage dir, one flat shape cap — which is precisely the model the tenant aggregate and hash ring replace.

Migration guidance for an existing Electric deployment is documentation, not code: a table of which Restdis setting serves the same purpose.

---

## Scope

**In scope:**

- `restdis_shape` umbrella child: shape definitions, handles, append-only chunked log, sparse offset index, filter index, per-shape consumers.
- `GET /v1/shape` on `RestdisServer.HTTP.Endpoint` with the full parameter, header, message, and status-code contract above.
- `DELETE /v1/shape` behind `allow_shape_deletion`.
- Initial snapshot via PostgREST with LSN-bracketed, idempotent-apply consistency.
- Long-poll live mode with in-process request collapsing; SSE transport.
- Where-clause parsing and in-process evaluation over **exactly** Electric's documented supported subset — no more, no less — with move-in/move-out.
- Hash-indexed shape filter with flat throughput vs. shape count.
- Gatekeeper auth mode binding shape definitions to API keys server-side.
- Conformance suite run against the published Electric client packages.

**Out of scope:**

- **Server-side / operational compatibility.** No `ELECTRIC_*` environment variables, no Electric storage layout, no Electric-shaped config surface. Compatibility is client-side only. See "Compatibility boundary" above.
- **Any where-clause construct outside Electric's documented subset**, even where it would be easy to add. A superset is a divergence: shapes that work on Restdis and 400 on Electric make migration one-way and break the drop-in claim in the other direction.
- **Writes.** Same deliberate scope reduction as Electric: no write path, no conflict resolution, no CRDTs. Writes go to PostgREST as today.
- **Include trees / multi-table shapes.** Electric does not have them either; parity is the bar.
- **Mutable shape definitions.** A changed definition is a new handle, as in Electric.
- **Electric's legacy (pre-2024) Satellite WebSocket protocol, DDLX, or client-side SQLite ownership.** Dead surface.
- **PGlite / `y-electric` server-side support.** These are client-side libraries; they work if the log is correct, and are validated but not built.
- **Non-Postgres origins.**
- Replacing `PGRST.QUERY`. The shape API is additive; the RESP surface is untouched.

---

## Phase 1: Shape Log and Static Reads

Delivers a durable shape log and a `GET /v1/shape` that serves a snapshot and resumes by offset. No live mode, no filtering.

1. Add `restdis_shape` as the fifth umbrella child, with boundary enforcement in `mix check.boundary`.
2. Define `RestdisShape.Definition` (table, columns, where, params) and `RestdisShape.Handle` (truncated SHA-256 over the canonical definition, per tenant, formatted `{hash}-{epoch_ms}`).
3. Implement `RestdisShape.Log`: append-only chunk writer, chunk finalization at a size threshold, sparse offset index appended on finalization, and a reader that binary-searches the index then scans the chunk.
4. Implement `RestdisShape.Offset` over `RestdisBuster.Infra.LSN`: encode/decode `-1`, `0_inf`, `now`, `{lsn}_{op_offset}`; total ordering.
5. Implement `RestdisShape.Snapshotter`: record `L0`, page the shape's rows from PostgREST via `Restdis.Cache.Origin`, append each as an `insert` up to `0_inf`.
6. Add the `:shape` scope to `Restdis.Cache.Key` so chunks inherit per-tenant caps and flush.
7. Implement `GET /v1/shape` for `table`, `offset`, `handle`: 200 with the message array, `electric-handle`/`electric-offset`/`electric-schema` headers, and `cache-control`/`etag` marking immutable offsets immutable.
8. Return `409` with a `location` header when a handle is unknown or invalidated.
9. Return `400` for an unknown table or a projection omitting the primary key.

**Completion criteria:**

- A shape over a 10,000-row table serves a complete, correctly paginated snapshot; concatenating responses reproduces the table exactly.
- Resuming at any mid-snapshot offset returns exactly the operations after it, with no gap and no reordering.
- A request at an immutable offset returns a byte-identical body and the same `etag` across restarts.
- Log chunks survive a simulated node restart and serve warm data on recovery.
- Property test: for any sequence of appends and any resume offset, replaying from that offset reconstructs the same materialized map as replaying from `-1`.

**Risks:**

- Chunked-file storage is new code on the critical path. Electric's own numbers say the general-purpose-KV approach fails here, so the risk of *not* doing this is higher. Benchmark against the PRD Phase 1 target (10k writes/sec per tenant) before Phase 2.
- Handle stability across deploys. Any input to the hash that varies with OTP version, node, or map iteration order breaks every client at once. The canonicalization function needs a dedicated property test.

---

## Phase 2: Live Mode and Client Conformance

Delivers real-time updates and the first end-to-end proof of drop-in compatibility.

1. Add a `:shape_append` dispatch target in `RestdisBuster.Dispatcher`, alongside invalidate and refresh.
2. Implement `RestdisShape.Consumer`: one GenServer per active shape, appending matching changes to its log, hibernating when idle.
3. Require and verify `REPLICA IDENTITY FULL` on shape-backing tables at subscription time; 400 with a remediation message if absent.
4. Implement long-poll: hold the request until new data or timeout; on timeout return 200 with only an `up-to-date` control message.
5. Implement in-process request collapsing: all waiters on `(tenant, handle, offset)` share one waiter set and are woken by a single append.
6. Implement `columns` projection, validating that the primary key is included.
7. Implement `secret` gating and gatekeeper mode: shape definitions resolved from tenant config by name; client-supplied definition params rejected in this mode.
8. Constrain `RestdisBuster.Infra.LSNStore` to confirm the slot only at an LSN persisted by every active shape consumer.
9. Wire per-tenant shape eviction to `409` rather than silent drop.
10. Add metrics: active shapes per tenant, append latency, live waiters, collapse ratio, 409 rate by cause.

**Completion criteria:**

- `@electric-sql/client`'s `ShapeStream` and `Shape` consume a Restdis shape end to end with only the `url` changed, and `useShape` from `@electric-sql/react` re-renders on write.
- A committed Postgres write appears in a live long-poll response within 2 seconds.
- 1,000 concurrent live requests on one shape produce exactly one append-driven wakeup path and one response body.
- Killing the node holding the WAL tailer loses no appended operation: after failover and LSN resume, every client's materialized state matches Postgres.
- A shape evicted under per-tenant caps produces a 409 with a usable `location`, and the client recovers to correct state.

**Risks:**

- Live long-polls hold connections. Restdis's collapsing makes this a memory question rather than a socket-fan-out question, but per-tenant waiter caps are required before load testing.
- Slot-confirmation now depends on the slowest shape consumer. A stuck consumer holds back WAL and risks retention bloat — the same footgun Electric documents. Needs a watchdog that kills and 409s a consumer that falls beyond a threshold, trading one shape's resync for cluster health.

---

## Phase 3: Where Clauses and Move-In/Move-Out

Delivers partial replication, the feature that makes shapes worth having.

1. Integrate `datafusion-sqlparser-rs` via Rustler, parsing `where` with `PostgreSqlDialect` into an AST at subscription time only.
2. Implement `RestdisShape.Eval`: evaluation over exactly the documented subset (comparison, logical, arithmetic, bitwise, `LIKE`/`ILIKE`, array operators, null/boolean tests, `IN`/`NOT IN`, `BETWEEN`, `ANY`/`ALL`, `lower`/`upper`/`coalesce`/`greatest`/`least`).
3. Reject anything outside the subset at subscription time with a `400` naming the unsupported construct.
4. Implement `params` / `$1` positional interpolation with no string concatenation into SQL text.
5. Implement move-in/move-out: evaluate the predicate against both the pre-image and post-image of every update; emit `insert` on newly-matching, `delete` on newly-non-matching.
6. Implement `replica=full` so update and delete messages carry `old_value`.
7. Implement `RestdisShape.Filter`: hash index from `(table, column, constant) -> MapSet(shape_handle)` for `field = constant`, `constant = field`, `field IN list`, `array_field @> constant`, `const = ANY(array_field)`, and `AND`/`OR` combinations. Mixed clauses filter on the optimized part first, then iterate survivors.
8. Add metrics: filter index hit rate, shapes evaluated per WAL event, throughput vs. shape count.

**Completion criteria:**

- Every expression in Electric's documented supported subset produces the same match/no-match decision as Postgres evaluating the same predicate, verified by a differential property test against a live Postgres.
- Every expression outside the subset returns 400 at subscription. No shape is ever accepted and then mis-filtered.
- An update that moves a row into a shape emits an `insert`; one that moves it out emits a `delete`; the client's materialized map matches a fresh snapshot in both cases.
- Throughput stays flat at the Phase 2 measured rate from 10 to 1,000 optimized shapes, and degradation with non-optimized clauses is measured and documented.

**Risks:**

- Predicate evaluation divergence from Postgres is a correctness *and security* bug: a wrong `true` leaks another tenant's row. The differential test against real Postgres is the gate, not a nice-to-have.
- Rustler puts parsing in a NIF, so a long parse blocks a scheduler. Parse on a dirty CPU scheduler with an input size limit, and only at subscription time — never on the WAL hot path. Safe Rust removes the memory-safety class of failure, not the scheduler-blocking one.
- `datafusion-sqlparser-rs` is a SQL parser, not Postgres itself, so its AST is not guaranteed to agree with Postgres on every literal, cast, and operator-precedence corner. That gap is exactly what the differential test against live Postgres is for; any disagreement is resolved by narrowing what we accept, never by guessing.

---

## Phase 4: Transport and CDN Parity

Delivers the remaining transport surface and validates cache behaviour end to end.

1. Implement `live_sse=true`: SSE framing with `: keep-alive` comments every 21 seconds.
2. Implement the `cursor` cache-busting parameter for live reconnects.
3. Emit `cache-control` with `max-age` and `stale-while-revalidate` matching Electric's semantics: immutable for settled offsets, short-lived for live responses.
4. Validate behind Nginx, Caddy, and one commercial CDN that request collapsing works and that no live response is cached as immutable.
5. Verify the client's documented SSE fallback (reverting to long-poll after repeated quick closes behind a buffering proxy) behaves correctly against Restdis.
6. Load test: 100,000 concurrent live clients across 100 tenants and 1,000 shapes, with and without a CDN in front, measuring memory, P99 latency, and origin request count.

**Completion criteria:**

- Both transports deliver identical logical message sequences for the same shape.
- With no CDN, 100k concurrent live clients are served with flat memory and P99 propagation under 2 seconds.
- With a CDN, origin request count per shape per interval is ~1 regardless of client count.
- No cache layer ever serves a stale body at an immutable offset, verified by a chaos test that mutates during a cached read.

**Risks:**

- Cache-header semantics are easy to get subtly wrong and catastrophic when wrong — a mis-marked live response cached as immutable pins clients on stale state permanently. Every header combination gets an explicit test.

---

## Phase 5: Direct-Postgres Snapshots and `changes_only`

Delivers exact snapshot dedup and the remaining `log` mode where a direct pool is available.

1. Add an optional per-tenant direct Postgres pool for snapshotting, separate from the replication connection.
2. Implement the exact snapshot path: read-only transaction, record `pg_current_snapshot()`, and skip buffered transactions with `xmin < xid < xmax and xid not in xip_list`.
3. Once the first transaction with `xid >= xmax` is logged, stop comparing xids for that shape, avoiding 32-bit wraparound concerns.
4. Implement `log=changes_only` with the `snapshot-end` control message carrying the snapshot descriptor; return 400 when no direct pool is configured.
5. Document per-tenant which snapshot path is in use, and expose it as a metric.

**Completion criteria:**

- On the direct path, no row appears both in the snapshot and as an early logged insert.
- On the PostgREST path, duplicates are bounded, measured, and provably converge to the same materialized state.
- `changes_only` clients reconstruct the same state as `full` clients for the same shape.

**Risks:**

- Two snapshot paths is two code paths to keep semantically identical. They share the same log-append interface and the same property tests, run against both.

---

## Phase 6: Subquery Shapes and Production Hardening

1. Implement `field IN (subquery)` with cross-table dependency tracking, so rows move in and out when the subquery result changes without the row itself changing — incrementally, including under compound `AND`/`OR`/`NOT`.
2. Implement periodic schema reconciliation (60s) catching changes that emit no relation message, invalidating affected shapes.
3. Enforce per-tenant shape caps: max shapes, max log bytes, max live waiters, with 429 and actionable errors.
4. Extend the Grafana dashboard: shapes per tenant, append latency, WAL-to-client propagation, 409 rate by cause, collapse ratio, log disk per tenant.
5. Implement log compaction preserving the temporal ordering of key creation and deletion.
6. Publish a client-migration guide and a compatibility matrix stating exactly which protocol features and where-clause constructs are supported, plus a documentation-only table mapping Electric operational settings to their Restdis equivalents.
7. Run the conformance suite in CI against the published Electric client packages, pinned by version, as a merge gate.

**Completion criteria:**

- Archiving a parent row moves its children out of a subquery-filtered shape incrementally, with no 409.
- Compaction reduces log size without changing any client's materialized result, verified by property test.
- The conformance suite is green in CI and fails the build on regression.
- The compatibility matrix is published and every "unsupported" entry corresponds to a 400 at subscription time, never to silent divergence.

---

## Compatibility Matrix (target state at Phase 6)

| Capability | Electric | Restdis | Notes |
| --- | --- | --- | --- |
| `@electric-sql/client` `ShapeStream` / `Shape` | ✅ | ✅ | URL change only. |
| `@electric-sql/react` `useShape` | ✅ | ✅ | Via the client. |
| `@tanstack/electric-db-collection`, `useLiveQuery` | ✅ | ✅ | Via the client. |
| `y-electric` | ✅ | ✅ | Client-side; correct log is sufficient. |
| `electric_client` (Hex), `Phoenix.Sync`, Ecto-derived shapes | ✅ | ✅ | HTTP protocol only. Embedded-in-the-same-BEAM mode is not offered. |
| Long-poll live mode | ✅ | ✅ | Phase 2. |
| SSE live mode | ✅ | ✅ | Phase 4. |
| Where clauses (documented subset) | ✅ | ✅ | Phase 3, differentially tested against Postgres. |
| Subquery where clauses | ✅ | ✅ | Phase 6. |
| `columns`, `replica`, `params` | ✅ | ✅ | Phases 2–3. |
| `log=changes_only` + `snapshot-end` descriptor | ✅ | ⚠️ | Requires a direct Postgres pool; 400 otherwise. |
| Include trees / multi-table shapes | ❌ | ❌ | Neither. |
| Mutable shape definitions | ❌ | ❌ | Neither. |
| Write path / conflict resolution | ❌ | ❌ | Deliberate in both. |
| Multi-tenant on one deployment | ❌ | ✅ | Restdis's tenant aggregate. |
| Native auth / gatekeeper | ❌ | ✅ | No user-built proxy required. |
| CDN required for fan-out scale | ✅ | ❌ | In-process collapsing; CDN optional. |
| Horizontal read scaling | ⚠️ read replicas | ✅ | Consistent hash ring + global chunk replication. |
| Replication slots consumed | 1 per Electric instance | 1 per cluster, shared with existing invalidation | Reuses the existing tailer. |

---

## Open Questions

| # | Question | Current lean |
| --- | --- | --- |
| ~~1~~ | ~~Do shape logs count against the existing per-tenant CubDB budget?~~ | **Resolved.** Separate budget: shape logs have different growth and eviction semantics than query cache entries, and one shared cap means a large shape silently evicts hot query results. CubDB is slated for replacement; it holds shape *metadata* only for the MVP, so shape log storage does not deepen the dependency. |
| ~~2~~ | ~~Which SQL parser?~~ | **Resolved.** `datafusion-sqlparser-rs` via Rustler. |
| 3 | Should gatekeeper mode be the only mode on the managed platform? | Yes for multi-tenant platform deployments; open mode for self-hosted single-tenant. Confirm with the platform team. |
| 4 | How do shapes interact with the existing `restdis_replicator` always-live datasets? | They overlap substantially. Recommend shapes become the strategic surface and the replicator's KV datasets stay for RESP-only consumers, rather than building a third refresh path. Needs a product decision. |
| 5 | What is the migration story for a tenant already running Electric — cutover or dual-run? | Dual-run: point a fraction of clients at Restdis, diff materialized state against Electric for the same shape definition, then cut over. The log is deterministic enough to diff. |
| 6 | Do we track Electric's protocol post-Databricks/Neon? | Pin to the 1.x protocol and the published client majors. The engine stays Apache 2.0, so the protocol is documented and forkable, but roadmap control now sits with Databricks — a compatibility target we follow, not one we commit to matching indefinitely. |
