# RFC: Supabase Stack Integration Layer

---

## Problem

Restdis today caches PostgREST responses. Supabase is more than PostgREST: Realtime,
Edge Functions, Auth, and Storage each make their own round trips to the database or to
managed services, and each of those round trips is a candidate for the same
cache-and-bust treatment. Right now every one of those paths goes straight to origin on
every request, which means duplicate load on self-hosted Postgres, duplicate load on the
Supabase platform services, and no shared mechanism for reducing either.

Restdis already owns the primitive that generalizes across all of them: an HTTP proxy
that receives a `GET`, fetches it from origin, and caches the result under a
WAL-invalidated key. This RFC extends that primitive to the rest of the Supabase stack,
and adds a general-purpose "prefer read replica" tenant setting that benefits every
integration built on top of Postgres.

### Who is asking for this

- **Platform customers** running self-hosted Supabase who want the same load-shedding
  Restdis gives PostgREST today extended to Realtime, Edge Functions, Auth, and Storage.
- **Supabase-hosted customers** with a read replica provisioned who want Restdis to
  prefer it automatically instead of hammering the primary.

### Why this matters

Every uncached Realtime "get me the latest N rows" query, every Edge Function `GET`,
every Auth user lookup, and every Storage metadata fetch is a repeated, cacheable read
that currently hits origin every time. WAL-driven invalidation already solves
correctness for PostgREST; the same mechanism solves it here. Read replica preference
compounds the effect: any cache miss that falls through to Postgres can be steered away
from the primary whenever the tenant has a replica.

---

## Background

This RFC builds directly on the architecture in `PRD.md`. It does not introduce a new
umbrella app for PostgREST, Storage, Auth, or Edge Functions caching; it teaches the
existing `restdis_server` (HTTP proxy), `restdis_cache` (three-layer cache), and
`restdis_buster` (WAL tailer) about three new origin types.

Three of the four integrations reduce to the same base primitive already implemented for
PostgREST:

> Receive an HTTP `GET`, fetch it from a declared origin, cache the result, serve it on
> repeat, bust it on the matching WAL event.

### Realtime builds on `restdis_electric`, not a new primitive

`ELECTRIC_PRD.md` adds a fifth umbrella application, `restdis_electric`, that already
solves the exact problem this RFC originally proposed solving from scratch: an
ordered, bounded, WAL-fed log of row-level changes for a declared subset of a table
(a "shape"), served over HTTP with resume-by-offset semantics. That is the same shape
as "follow a table or channel, keep the last N changes, let a client catch up without
hitting Postgres."

Building a second, bespoke ring-buffer primitive for Realtime follow mode alongside
`restdis_electric`'s shape log would leave Restdis with two overlapping append-only log
implementations doing the same job with different retention and read semantics.
`ELECTRIC_PRD.md` is explicit about avoiding exactly this split for
`restdis_replicator`'s always-live datasets ("One storage layer, shared with
`restdis_replicator`"). This RFC applies the same reasoning: Realtime follow mode is a
Restdis-native client (not an Electric-protocol client) of the shape log that
`restdis_electric` already builds, not a fourth storage model.

Concretely, the Realtime phase below (Phase 5) depends on `restdis_electric`'s public
API — `RestdisElectric` for handles/reads and `RestdisElectric.Definition` for shape
construction — the same way `restdis_server`'s `/v1/shape` route does. It adds no new
append-only store. The `RT.FOLLOW` / `RT.CHANGES` Redis-protocol commands described
below are a second front door onto the same shape log that `GET /v1/shape` exposes over
HTTP, sized and retained per Restdis's own configuration rather than Electric's client
protocol.

---

## Scope

**In scope:**

- Tenant-level "prefer read replica" setting that applies to every origin fetch that
  goes through Postgres (PostgREST, Auth, Storage metadata), not just PostgREST.
- Five extensions to PostgREST query caching.
- Storage object/bucket metadata caching, WAL-driven busting on storage schema changes.
- Auth user-data caching with mandatory redaction of sensitive fields, WAL-driven busting
  on the `auth.users` table (and configured related tables).
- Realtime "follow" commands (`RT.FOLLOW` / `RT.CHANGES`): subscribe to a channel or
  table and read the last N changes as a change-log query, implemented as a
  Redis-protocol front door onto `restdis_electric`'s shape log rather than a new
  storage engine.
- Edge Function `GET` caching, transparent when routed through Restdis.

**Out of scope:**

- Caching non-`GET` methods on any of these origins (mutations still bypass the cache).
- Realtime broadcast/presence channels (ephemeral, no backing table) — follow mode
  requires a WAL-backed table or a Postgres Changes channel.
- Full Storage file content caching (only metadata; file bytes stay out of scope for MVP).
- Automatic read replica lag detection or failover — same limitation as the existing
  PostgREST read replica routing.
- Demo/reference integration harnesses (Express, NGINX, or otherwise) — tracked
  separately from this RFC.

---

## Phase 1: Read Replica Preference

Generalizes the existing PostgREST-only read replica routing (`PRD.md`, "Read Replica
Routing") to every origin fetch that goes through Postgres. Ships first because every
later phase that adds a new Postgres-backed origin (Storage, Auth) inherits it for free.

1. Add `prefer_read_replica: boolean` to tenant config alongside the existing
   `read_replica_url`.
2. Generalize the origin-fetch routing helper currently used only by the PostgREST path
   so any Postgres-backed origin fetch consults tenant config for replica preference
   before choosing a target.
3. Default to preferring the replica whenever one is configured, matching current
   PostgREST behavior. No automatic fallback to the primary if the replica is
   unreachable — the request fails, consistent with the existing PostgREST replica
   behavior.
4. Allow a tenant to opt a specific resource path or table out of replica routing when a
   read must be primary-consistent.
5. Confirm WAL tailing is unaffected: logical replication always connects to the primary
   regardless of this setting, since only the primary exposes the replication slot.

**Completion criteria:**

- With `prefer_read_replica: true` and a replica URL set, all PostgREST origin fetches
  route to the replica (already true today) and the setting is now read from a shared
  helper other integrations can call.
- Opting a single resource path out of replica routing does not affect other paths for
  the same tenant.
- WAL tailing continues to connect to the primary when replica preference is enabled.

**Risks:**

- None new; this phase only lifts existing PostgREST-specific logic into a shared helper.

---

## Phase 2: PostgREST Caching Extensions

Five ways to extend the existing PostgREST cache beyond single-query caching.

1. **Query-shape templates.** Let a tenant declare a cache policy per resource path with
   parameter allow-lists/ignore-lists (e.g. ignore `apikey`, normalize pagination params
   so `?limit=10&offset=0` and `?offset=0&limit=10` collapse to the same key), instead of
   keying purely on `phash2` of the full parameter map.
2. **Embedded-resource-aware invalidation.** Extend the reverse index to record every
   embedded table touched by a query (parsed from the `select` clause) for responses
   using `select=*,child(*)` resource embedding, not just the root table, so a WAL event
   on the child table busts the parent query's cache entry too.
3. **Negative/empty-result caching with a short TTL.** Cache `[]` results with a distinct,
   shorter default TTL (configurable) so polling for "has this appeared yet" doesn't hit
   origin every time, while keeping staleness bounded tightly.
4. **Partial-response stitching for range/pagination requests.** Cache each page of a
   paginated query independently, keyed by `(resource, filters, range)`, and serve
   sequential page requests entirely from cache once the full range has been walked once
   by any client.
5. **RPC-aware caching with argument normalization.** Add a declared schema per
   `/rpc/<function>` (which args are order-independent, which are cacheable at all — some
   RPCs are effectively mutations) so tenants can opt specific stored procedures into
   caching with correct key normalization.
6. *(bonus)* **Tenant-declared cache warmth tiers.** Let a tenant mark specific resource
   paths as "hot" (always rewarm, never evict below TTL floor) versus "cold" (cache only
   on demand, evict aggressively), replacing today's single global rewarm policy.

**Completion criteria:**

- A tenant-declared parameter ignore-list collapses reordered/no-op-varied requests to
  the same cache key.
- A WAL event on a child table referenced only via `select` embedding busts the parent
  query's cache entry.
- Empty-result entries expire on their own configurable TTL, distinct from non-empty
  results for the same resource.
- A previously-walked pagination range serves entirely from cache with zero PostgREST
  requests on repeat.
- A tenant can mark a specific RPC function cacheable with normalized argument keys
  without affecting other RPCs.

**Risks:**

- Query-shape templates and warmth tiers add per-resource config surface area; validate
  tenant config schema changes don't regress existing untemplated resources to a
  degraded default.
- Embedded-resource reverse-index entries multiply write-path cost similarly to the
  existing array-result reverse index; document the same trade-off.

---

## Phase 3: Storage Integration

Caches `GET` reads of Storage metadata: bucket listings, object metadata (name, size,
content-type, `updated_at`, custom metadata), not file bytes. Ships before Auth and
Realtime because it reuses the existing reverse-index/WAL mechanism with no new
invalidation plumbing — `storage.objects` already lives in Postgres.

1. Add HTTP proxy routes for Storage `GET` endpoints (bucket listing, object metadata) to
   `restdis_server`, following the same origin-fetch/cache-populate pattern as PostgREST.
2. Cache key: `(bucket, object_path_or_prefix, phash2(query_params))`, same
   canonicalization approach as PostgREST.
3. Extend the reverse index to cover `storage.objects` rows so WAL events on that table
   bust the corresponding bucket/object metadata entries.
4. Apply Phase 1 read replica preference to Storage metadata queries that hit Postgres.

**Completion criteria:**

- A cached object-metadata response is served without an origin fetch on repeat.
- An insert/update/delete on `storage.objects` busts the corresponding cached metadata
  entry within the same WAL-invalidation latency bound as PostgREST tables.
- Storage metadata queries route to the read replica when the tenant has one configured
  and preferred.

**Risks:**

- Bucket-listing queries (prefix scans) may touch many objects per response; confirm
  reverse-index growth stays bounded the same way large PostgREST array responses are
  documented today.

---

## Phase 4: Auth Integration — Caching With Mandatory Redaction

Caches `GET` reads of Supabase Auth user data (`auth.users`, and any tenant-declared
related tables such as `auth.identities`) so repeated "who is this user" lookups don't
hit the Auth service or Postgres on every request. Ships after Storage because it
reuses the same WAL-busting mechanism plus a hard redaction boundary that needs its own
validation.

1. Add HTTP proxy routes for Auth `GET` endpoints to `restdis_server`.
2. Implement a fixed, code-defined field allow-list (not tenant-configurable) applied to
   every Auth-derived value before it is written to ETS or CubDB — strips password
   hashes, MFA secrets, recovery tokens, `encrypted_password`, and confirmation tokens.
3. Exclude `auth.sessions` and `auth.refresh_tokens` from caching entirely, not just
   redaction, at the routing layer so they never reach the cache write path.
4. Extend the reverse index to cover `auth.users` (and configured related tables) so WAL
   events bust the corresponding cached entries, reusing the existing mechanism.
5. Apply Phase 1 read replica preference to Auth queries that hit Postgres.

**Completion criteria:**

- A cached Auth user lookup never contains a field outside the code-defined allow-list,
  verified by a test that asserts the redaction boundary applies to both ETS and CubDB
  writes, not just the HTTP response.
- No entry for `auth.sessions` or `auth.refresh_tokens` reaches the cache under any
  configuration.
- A WAL event on `auth.users` busts the corresponding cached entry within the same
  latency bound as PostgREST tables.

**Risks:**

- The redaction allow-list must be reviewed against the full Auth schema, including
  fields added in future Supabase Auth versions; add a schema-diff check to CI so new
  sensitive columns don't silently become cacheable.

---

## Phase 5: Realtime Integration — Follow Mode on `restdis_electric`

Delivers `RT.FOLLOW` / `RT.CHANGES` as a Redis-protocol client of `restdis_electric`'s
shape log (`ELECTRIC_PRD.md`). Ships after the other Postgres-backed integrations, and
depends on `restdis_electric` Phase 1 (the shape log and reads without live updates) and
Phase 2 (live updates) having landed first. It adds no new append-only store: the
bounded, WAL-fed change-log this RFC originally proposed building is exactly what a
shape already is.

### Model

A tenant issues a **follow** command against a channel or a table:

```
RT.FOLLOW <table_or_channel> [LIMIT <n>] [FILTER <postgres_changes_filter>]
```

`RT.FOLLOW` translates its arguments into a `RestdisElectric.Definition` — `table` maps
directly, `FILTER` maps to the shape's `where` clause (subject to the same supported
subset and `400`-on-reject rules as `ELECTRIC_PRD.md` Phase 3), and `LIMIT` sets the
shape's configured retention length instead of Electric's default unbounded-with-
compaction log. This calls the same `RestdisElectric` public API that
`RestdisServer.HTTP.Electric` calls for `GET /v1/shape`; it does not talk to
`restdis_buster` directly, and it does not open a second WAL subscription for a table
already followed by another shape or by `PRD.md` Phase 5 table replication.

### Read path

```
RT.CHANGES <table_or_channel> [SINCE <lsn_or_cursor>] [LIMIT <n>]
```

Maps to a read of the shape log by offset: `SINCE` becomes the Electric-format
`{lsn}_{op_offset}` offset (or `-1` when omitted, to start from a snapshot), and the
response is the same ordered insert/update/delete messages the HTTP shape API returns,
translated into the Redis protocol. No database round trip, and no code path outside
`RestdisElectric`'s read API.

### Implementation steps

1. Implement `RT.FOLLOW` in `restdis_server`'s Redis command dispatch: build a
   `RestdisElectric.Definition` from the command arguments, call `RestdisElectric` to
   obtain a handle, and store the `(tenant, table_or_channel) -> handle` mapping needed
   to resolve later `RT.CHANGES` calls.
2. Map `LIMIT` to the shape's configured retention length (`ELECTRIC_PRD.md`, "How we
   store the shape log"), as a per-follow override of the tenant default, rather than
   introducing a second cap concept.
3. Implement `RT.CHANGES`: resolve the stored handle, convert `SINCE`/`LIMIT` into an
   offset and range, call `RestdisElectric`'s read API, and translate the returned
   messages into a RESP response.
4. Implement a non-blocking variant that surfaces `RestdisElectric.await/3` (from
   `ELECTRIC_PRD.md` Phase 2) so a client can long-poll `RT.CHANGES` for new events the
   same way `live=true` works over HTTP, without introducing a second live-update
   mechanism.
5. Translate a `409`/must-refetch result from `RestdisElectric` (handle evicted,
   retention window exceeded, replication slot recreated) into a Redis-protocol error
   that tells the client to re-issue `RT.FOLLOW` from the beginning, mirroring the HTTP
   `location` header's role.

**Completion criteria:**

- `RT.FOLLOW` on a table with no prior shape creates exactly one
  `RestdisElectric` shape and one WAL subscription for it, verified against
  `restdis_electric`'s per-shape process count.
- `RT.CHANGES` returns the last N events for a followed table entirely from
  `RestdisElectric`'s log, with no Postgres round trip.
- `RT.FOLLOW` on a table already followed via `GET /v1/shape` with an identical
  definition reuses the existing shape and handle rather than creating a second one.
- A shape evicted or invalidated for any of the reasons in `ELECTRIC_PRD.md`'s "Every
  reason we return `409`" table surfaces as a distinct, documented error to the
  `RT.CHANGES` caller rather than silently returning stale or empty data.

**Risks:**

- This phase has a hard dependency on `restdis_electric` Phases 1–2 shipping first;
  sequencing this RFC's Realtime work against `ELECTRIC_PRD.md`'s own phases is a
  cross-RFC scheduling risk, not just an implementation one.
- `FILTER` reuses the `where`-clause subset from `ELECTRIC_PRD.md` Phase 3
  (`RestdisElectric.Eval`); until that phase ships, `RT.FOLLOW ... FILTER ...` must
  return an explicit "not yet supported" error rather than silently ignoring the filter.
- Retention (`LIMIT`) is a per-shape configuration value, not a live parameter a client
  can renegotiate after the fact; changing it for an existing follow requires issuing a
  new `RT.FOLLOW`, which produces a new handle — document this rather than silently
  truncating or growing an existing log.

---

## Phase 6: Edge Function Query Caching

Ships last because it is the one origin type with no backing table Restdis can observe,
so it can't reuse WAL-driven busting as a correctness mechanism, only as an optional hint.

1. Add HTTP proxy routes for `GET /functions/v1/<name>?...` to `restdis_server`.
2. Implement cache key derivation: `(function_name, phash2(query_params +
   relevant_headers))`, where key-relevant headers (e.g. `Authorization` for per-user
   functions) are a per-function tenant declaration.
3. Apply TTL/rewarm cache policy controls identical to the existing PostgREST HTTP proxy
   path (`SC-Cache-TTL`, `SC-Cache-Rewarm`).
4. Implement optional best-effort WAL invalidation: a tenant may declare which tables a
   given function reads, and a WAL event on those tables busts the function's cached
   entries the same way a PostgREST query would be busted.
5. Restrict caching to `GET` invocations only; `POST` and other mutating function calls
   always bypass the cache proxy entirely.

**Completion criteria:**

- A cached Edge Function `GET` response is served without invoking the function on
  repeat, within its configured TTL.
- Two requests differing only in a header not declared key-relevant produce a cache hit
  on the same entry.
- A tenant-declared table dependency for a function busts that function's cached entries
  on a matching WAL event.
- `POST` invocations to the same function path never populate or read the cache.

**Risks:**

- Caching responses keyed on `Authorization` header risks leaking one user's cached
  response to another if the header is omitted from the key by tenant misconfiguration;
  document this clearly and consider requiring `Authorization` in the key by default for
  functions with no explicit header declaration.

---

## Resolved Questions

| #   | Question                                     | Resolution                                                                                                    |
| --- | --------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| 1   | Does Realtime follow-mode execute queries?    | No. `RT.FOLLOW`/`RT.CHANGES` are a Redis-protocol front door onto a `restdis_electric` shape log, not a re-executed query and not a bespoke ring buffer. |
| 2   | Is Auth caching ever allowed to hold secrets? | No. Field allow-list enforced in code, applies to both ETS and CubDB, session/token tables excluded entirely.   |
| 3   | Does read replica preference cover Storage/Auth? | Yes, generalized from the PostgREST-only flag to any Postgres-backed origin fetch, delivered first in Phase 1. |
| 4   | Is Storage file content cached?               | No, metadata only. File bytes are out of scope for this phase.                                                  |
| 5   | Why does Read Replica Preference ship before the other integrations? | It is a small, low-risk generalization of existing logic that every later Postgres-backed phase (Storage, Auth) benefits from immediately. |
| 6   | Why does Realtime follow-mode ship after Storage and Auth?  | It depends on `restdis_electric` (`ELECTRIC_PRD.md`) Phases 1–2 landing first, which is a cross-RFC dependency the other phases don't have. |
| 7   | Does this RFC introduce a fourth storage model alongside cached responses, replicated key-value datasets, and the shape log? | No. Realtime follow mode is built entirely on the shape log `restdis_electric` already owns; see "Realtime builds on `restdis_electric`, not a new primitive". |
