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
umbrella app; it teaches the existing `restdis_server` (HTTP proxy), `restdis_cache`
(three-layer cache), and `restdis_buster` (WAL tailer) about four new origin types, plus
a channel/table "follow" mode that is new: a change-log style cache rather than a
query-result cache.

All four integrations reduce to the same base primitive already implemented for
PostgREST:

> Receive an HTTP `GET`, fetch it from a declared origin, cache the result, serve it on
> repeat, bust it on the matching WAL event.

The Realtime integration is the one exception that needs a new primitive: instead of
caching a single query result, it caches an append-only window of the last N observed
changes for a followed channel or table, independent of any specific query being
re-issued.

---

## Scope

**In scope:**

- Five extensions to PostgREST query caching (below).
- Realtime "follow" primitive: subscribe to a channel or replicated table, retain the
  last N events in memory + disk cache, serve them as a change-log query.
- Edge Function `GET` caching, transparent when routed through Restdis.
- Auth user-data caching with mandatory redaction of sensitive fields, WAL-driven busting
  on the `auth.users` table (and configured related tables).
- Storage object/bucket metadata caching, WAL-driven busting on storage schema changes.
- Tenant-level "prefer read replica" setting that applies to every origin fetch that
  goes through Postgres (PostgREST, Auth, Storage metadata), not just PostgREST.
- Two demo integration harnesses: a minimal Express server, and an NGINX config, each
  showing how to route traffic through the Restdis proxy layer.

**Out of scope:**

- Caching non-`GET` methods on any of these origins (mutations still bypass the cache).
- Realtime broadcast/presence channels (ephemeral, no backing table) — follow mode
  requires a WAL-backed table or a Postgres Changes channel.
- Full Storage file content caching (only metadata; file bytes stay out of scope for MVP).
- Automatic read replica lag detection or failover — same limitation as the existing
  PostgREST read replica routing.
- Building the demo Express/NGINX apps into anything production-supported; they exist to
  document the integration contract, not to ship as products.

---

## Part 1: PostgREST Caching Extensions

Five ways to extend the existing PostgREST cache beyond single-query caching:

1. **Query-shape templates.** Instead of keying purely on `phash2` of the full parameter
   map, let a tenant declare a cache policy per resource path with parameter
   allow-lists/ignore-lists (e.g. ignore `apikey`, normalize pagination params so
   `?limit=10&offset=0` and `?offset=0&limit=10` collapse to the same key). Reduces cache
   fragmentation from clients that vary parameter order or add no-op params.

2. **Embedded-resource-aware invalidation.** PostgREST responses using `select=*,child(*)`
   resource embedding span multiple tables. Extend the reverse index to record every
   embedded table touched by a query (parsed from the `select` clause), not just the
   root table, so a WAL event on the child table busts the parent query's cache entry
   too.

3. **Negative/empty-result caching with a short TTL.** A query that returns `[]` today
   still round-trips to PostgREST on every repeat. Cache empty results with a distinct,
   shorter default TTL (configurable) so polling for "has this appeared yet" doesn't hit
   origin every time, while keeping staleness bounded tightly.

4. **Partial-response stitching for range/pagination requests.** Cache each page of a
   paginated query independently, keyed by `(resource, filters, range)`, and serve
   sequential page requests entirely from cache once the full range has been walked once
   by any client. Avoids re-fetching page 1 through N-1 every time a client scrolls.

5. **RPC-aware caching with argument normalization.** PostgREST RPC calls
   (`/rpc/<function>`) currently cache on raw JSON body `phash2`. Add a declared schema
   per function (which args are order-independent, which are cacheable at all — some RPCs
   are effectively mutations) so tenants can opt specific stored procedures into caching
   with correct key normalization instead of leaving all RPCs to accidental cache misses.

6. *(bonus)* **Tenant-declared cache warmth tiers.** Let a tenant mark specific resource
   paths as "hot" (always rewarm, never evict below TTL floor) versus "cold" (cache only
   on demand, evict aggressively), replacing today's single global rewarm policy with
   per-resource weighting so limited ETS/CubDB budget favors known hot paths.

---

## Part 2: Realtime Integration — Follow Mode

### Model

A tenant issues a **follow** command against a channel or a replicated table:

```
RT.FOLLOW <table_or_channel> [LIMIT <n>] [FILTER <postgres_changes_filter>]
```

This does not execute a query. It registers interest with `restdis_buster`, the same WAL
tailer already consuming the replication slot for cache invalidation. From that point on,
every matching WAL event (INSERT/UPDATE/DELETE) for the followed table is appended to a
bounded ring buffer — last `n` entries, default configurable per tenant — held in ETS
(hot) and persisted to CubDB (durable). This is a change-log, not a materialized query
result: entries are the raw before/after row deltas from WAL, tagged with LSN and
timestamp.

### Read path

```
RT.CHANGES <table_or_channel> [SINCE <lsn_or_cursor>] [LIMIT <n>]
```

Serves directly from the ring buffer in ETS/CubDB. No database round trip. This gives
tenants a "what changed since I last looked" query — the same shape as a Realtime
Postgres Changes subscription — but servable as a point-in-time fetch instead of a
persistent socket, and without going back to Postgres to reconstruct history.

### Design notes

- Reuses `restdis_buster`'s existing per-AZ fan-out; a follow registration is just
  another dispatch target alongside cache invalidation, keyed by table the same way the
  reverse index is.
- Ring buffer size is a per-tenant, per-followed-table cap (analogous to the existing
  persist cap), not a per-tenant total, since hot tables need deeper history than cold
  ones.
- `RT.FOLLOW` on a table already covered by Phase 5 table replication reuses that
  subscription rather than opening a second one.
- Buffer eviction is pure FIFO once the cap is hit — no TTL, since the value proposition
  is "last N regardless of age."

---

## Part 3: Edge Function Query Caching

Same base primitive as PostgREST: a tenant routes an Edge Function invocation through
Restdis (`GET /functions/v1/<name>?...`), Restdis fetches it from the Edge Function
origin on miss, caches the response body + status + relevant headers, and serves cache
hits directly.

- Cache key: `(function_name, phash2(query_params + relevant_headers))`. Which headers
  are key-relevant (e.g. `Authorization` when a function is per-user) is a per-function
  tenant declaration, since Edge Functions have no schema to infer this from.
- No automatic WAL-based invalidation — Edge Functions have no backing table Restdis can
  observe by default. Cache policy is TTL/rewarm only, same controls (`SC-Cache-TTL`,
  `SC-Cache-Rewarm`) as the PostgREST HTTP proxy path.
- A tenant may optionally declare which tables a given function reads, letting the same
  WAL-driven busting apply as a best-effort invalidation hint — not correctness-critical,
  since the function itself remains the source of truth.
- Only `GET` invocations are eligible. `POST`/mutating function calls always bypass.

---

## Part 4: Auth Integration — Caching With Mandatory Redaction

Caches `GET` reads of Supabase Auth user data (`auth.users`, and any tenant-declared
related tables such as `auth.identities`) so repeated "who is this user" lookups don't
hit the Auth service or Postgres on every request.

- **Redaction is mandatory, not configurable.** Before any Auth-derived value is written
  to ETS or CubDB, it passes through a fixed field allow-list (e.g. `id`, `email`
  optionally per tenant policy, `role`, `created_at`, `app_metadata` subset) that strips
  known-sensitive columns: password hashes, MFA secrets, recovery tokens, raw
  `encrypted_password`, phone/email confirmation tokens. This allow-list lives in code,
  not tenant config, so a misconfigured tenant can't accidentally cache secrets.
- Cache busting reuses the existing WAL path: a WAL event on `auth.users` (or a
  configured related table) invalidates the corresponding reverse-indexed cache entries,
  same mechanism as any other table today.
- No `persist`/disk-durable caching of Auth data beyond the redacted field set — the
  redaction boundary applies uniformly to both ETS and CubDB, not just the network
  response.
- Session tokens, JWTs, and anything under `auth.sessions`/`auth.refresh_tokens` are
  excluded from caching entirely, not just redacted, since staleness there has security
  implications beyond simple correctness.

---

## Part 5: Storage Integration

Caches `GET` reads of Storage metadata: bucket listings, object metadata (name, size,
content-type, `updated_at`, custom metadata), not file bytes.

- Cache key: `(bucket, object_path_or_prefix, phash2(query_params))`, same
  canonicalization approach as PostgREST.
- WAL-driven busting: a WAL event on `storage.objects` (insert/update/delete) invalidates
  the reverse-indexed metadata entries for that bucket/object, same reverse-index
  mechanism as PostgREST tables — Storage metadata already lives in Postgres, so this is
  a direct reuse, not new WAL plumbing.
- File content caching is explicitly out of scope for this phase (documented above)
  since it introduces a different storage/eviction cost model (large blobs vs. small JSON
  rows) that deserves its own design.

---

## Part 6: Read Replica Preference

Generalizes the existing PostgREST-only read replica routing (`PRD.md`, "Read Replica
Routing") to every origin fetch that goes through Postgres.

- Tenant config gains a `prefer_read_replica: boolean` flag alongside the existing
  `read_replica_url`. When both a replica URL and the preference flag are set, **all**
  origin fetches that hit Postgres — PostgREST queries, Auth user lookups, Storage
  metadata queries — route to the replica by default. Edge Function and Realtime WAL
  tailing are unaffected (WAL replication requires the primary's logical replication
  slot; only read-path fetches are eligible for replica routing).
- Default is to prefer the replica whenever one is configured (matches the request:
  "default to read replica querying if it is provided"). A tenant can opt out per
  resource-path/table if a specific read must be primary-consistent.
- No automatic failover or lag detection, consistent with the existing PostgREST replica
  behavior — if the replica is unreachable, the request fails rather than silently
  falling back to the primary. This preserves the load-shedding guarantee: falling back
  automatically would defeat the purpose whenever the replica is under load, which is
  exactly when tenants need the offload most.

---

## Part 7: Demo Integration Harnesses

Two minimal, documentation-grade demos showing how to route traffic through the Restdis
proxy layer. Neither ships as a supported product; both live under an `examples/`
directory in this repo.

1. **Express demo.** A small Node/Express app with a handful of routes that proxy `GET`
   requests to Restdis's HTTP endpoint instead of calling PostgREST/Auth/Storage
   directly, forwarding the relevant `SC-Cache-*` headers. Demonstrates the integration
   contract for any Node-based backend.
2. **NGINX demo.** An `nginx.conf` using `proxy_pass` to route matching `GET` locations
   (e.g. `/rest/v1/`, `/auth/v1/user`, `/storage/v1/object/`) to the Restdis HTTP
   endpoint, with cache-control headers passed through. Demonstrates that no application
   code is required at all — an existing NGINX-fronted deployment can adopt Restdis by
   config change alone.

Both demos target the same underlying contract: a plain `GET` proxied to Restdis, which
performs the origin fetch and caching itself. Neither demo implements its own caching
logic.

---

## Resolved Questions

| #   | Question                                     | Resolution                                                                                                    |
| --- | --------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| 1   | Does Realtime follow-mode execute queries?    | No. It's a WAL-fed ring buffer per table/channel, read via `RT.CHANGES`, not a re-executed query.               |
| 2   | Is Auth caching ever allowed to hold secrets? | No. Field allow-list enforced in code, applies to both ETS and CubDB, session/token tables excluded entirely.   |
| 3   | Does read replica preference cover Storage/Auth? | Yes, generalized from the PostgREST-only flag to any Postgres-backed origin fetch.                          |
| 4   | Is Storage file content cached?               | No, metadata only. File bytes are out of scope for this phase.                                                  |
| 5   | Do the Express/NGINX demos implement caching? | No. They only proxy `GET`s to the existing Restdis HTTP endpoint; all caching logic stays in Restdis.           |
