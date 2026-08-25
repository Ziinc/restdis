# RFC: Restdis Implementation Plan

---

## Problem

PostgREST queries from tenant applications hit the database on every request. There is no shared caching layer between tenants and PostgREST. High-read workloads repeat identical queries, generating unnecessary database load and latency.

Tenants need a caching proxy that:

- Speaks the Redis protocol so existing Redis client libraries work unchanged.
- Caches PostgREST responses in-memory with configurable TTL and cache key control.
- Automatically invalidates or refreshes stale cache entries when underlying data changes via WAL.
- Supports always-live dataset replication for latency-critical reads.

No existing component in the Supabase stack provides this.

### Who is asking for this

- **Platform customers** with high-read, low-write workloads who want sub-millisecond response times without provisioning external Redis.

### Why this matters

Every PostgREST cache miss is a full database round-trip. For read-heavy tenants, this means redundant query execution, wasted connection pool capacity, and higher tail latency. A caching proxy eliminates repeated work. WAL-driven invalidation ensures correctness without manual cache management. The Redis protocol eliminates client-side integration cost.

---

## Background

### Architecture Overview

Restdis is an Elixir umbrella application with four child apps:

| App                      | Responsibility                                                                                                                                                                                                                                                                                           |
| ------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `restdis_server`     | Redis protocol listener (RESP). HTTP endpoint for PostgREST proxy. Parses commands, extracts tenant context, routes to cache layer. Proxies cache misses to PostgREST or read replica. Reads tenant config from Postgres. Owns rewarm scheduling.                                                        |
| `restdis_cache`      | Three-layer cache engine: ETS QueryCache, CubDB DiskCache, PostgREST origin fetch. One ETS table and one CubDB instance per tenant. Maintains the reverse index. Exposes internal API for lookups, writes, invalidation, and global disk replication.                                                    |
| `restdis_buster`     | GenSingleton process (via `syn`) tailing the cluster-wide WAL stream. Consumes 1 replication slot. Broadcasts changes per-AZ. Spawns worker processes per WAL event that read tenant config, look up reverse index, and dispatch invalidation (TTL mode) or refresh (replication mode) to the cache app. |
| `restdis_replicator` | Manages always-live KV datasets. On initial subscription, fetches full table or filtered subset from PostgREST. Stores as individual KV pairs in cache. On WAL change notification from buster, re-fetches affected rows and updates in place.                                                           |

### Three-Layer Cache

Reads resolve through three layers in order:

1. **Layer 1: QueryCache (ETS).** One ETS table per tenant. Hot cache. Key: `(tenant, {table_or_rpc_or_view, phash2(query_params_map)})`. Sub-millisecond.
2. **Layer 2: DiskCache (CubDB on NVMe).** Per-tenant CubDB instance. Key: `(table_or_rpc_or_view, phash2(query_params_map))`. Survives restarts. Concurrent reads, no file size cap, append-only compaction.
3. **Layer 3: PostgREST.** Origin fetch. Populates both Layer 1 and Layer 2. Optionally routes to tenant-configured read replica.

Entries written to disk cache replicate globally across the cluster.

### WAL Broadcasting

Same architecture proven in Logflare:

- One GenSingleton process tails the WAL stream. Exactly 1 replication slot per cluster. Registered via `syn`. On failure, another node takes over.
- Per-AZ fan-out via `syn` group registration. One node per AZ receives the WAL change and fans out locally. Bounds broadcast volume and prevents storms.
- Global mesh: all regions receive all WAL broadcasts if the cluster is fully connected.
- During rolling deploys, `syn` group membership updates automatically.

### Reverse Index

Maps `(table, primary_key) -> [cache_keys]`. Covers both single-row primary key queries and array results. For array results, every object's primary key in the response is extracted and indexed. This means a response with 500 objects creates 500 reverse index entries. Performance degrades linearly with array size. This trade-off is accepted and documented: WAL invalidation correctness applies universally, at the cost of higher write-path overhead for large array responses.

### Two Invalidation Modes

| Mode                    | WAL event behavior                                                      | TTL behavior                                    |
| ----------------------- | ----------------------------------------------------------------------- | ----------------------------------------------- |
| **TTL-based** (default) | WAL change busts the cache entry immediately, even if `persist` is set. | Entry expires at TTL. Rewarm extends on demand. |
| **Replication**         | WAL change triggers automatic refresh, not deletion.                    | No TTL expiry. Data is always live.             |

WAL event worker processes read tenant config (cached locally) to determine mode per table. Tenant config changes invalidate caches for the affected table and repopulate.

### Redis Protocol Compatibility

Supported command set for MVP: `GET`, `SET`, `MGET`, `DEL`, `TTL`, `EXISTS`, `PING`, `AUTH`. Core set only. No `SUBSCRIBE`, `SCAN`, or `KEYS`.

Two custom commands extend functionality:

- `PGRST.QUERY <path> [TTL <seconds>] [REWARM <seconds>]` fetches from PostgREST and caches the result. Returns the canonical cache key in the response.
- `PGRST.POLICY <cache_key> [TTL <seconds>] [REWARM <seconds>] [PERSIST]` updates cache policy on an existing entry without re-fetching.

Both are also available via HTTP with corresponding headers.

Authentication uses Supabase API keys via the `AUTH` command. MVP ships unauthenticated. Auth enforcement is a post-MVP hardening step.

### Node Distribution

Nodes in a regional cluster use consistent hashing by tenant ID. Incoming requests route to owning nodes. `libcluster` manages cluster membership. This gives each tenant a predictable memory and disk footprint.

### Resource Limits (MVP)

| Resource                       | Limit       |
| ------------------------------ | ----------- |
| ETS memory per tenant per node | 500 MB      |
| CubDB disk per tenant per node | 500 MB      |
| Persist entry cap per tenant   | 50,000 keys |

### Read Replica Routing

Tenant config specifies a read replica URL. When set, all PostgREST origin fetches route to the replica. No automatic failover or lag detection. If the replica is unreachable, the request fails.

---

## Scope

**In scope:**

- Elixir umbrella project with four child apps.
- Redis RESP protocol server with core command support.
- HTTP endpoint for PostgREST cache proxy.
- Two-layer in-process cache (ETS + CubDB).
- PostgREST origin fetch with read replica routing.
- Reverse index for WAL-driven cache invalidation across all query types.
- WAL-based cache invalidation (TTL mode) and refresh (replication mode).
- Demand-driven rewarm scheduling.
- Persist-to-disk with per-tenant caps.
- Always-live table replication as KV dataset.
- Cluster distribution via consistent hash ring.
- Global disk cache replication.
- Tenant config storage in Postgres.

**Out of scope:**

- Full Redis command set. Only the subset defined in Phase 2.
- Redis Cluster protocol (MOVED, ASK). Clients connect to a single endpoint.
- Redis Sentinel.
- Redis pub/sub beyond what is needed for internal invalidation.
- Caching of PostgREST mutations (POST, PATCH, DELETE).
- Multi-tenant database provisioning. Tenant databases already exist.
- Dashboard UI. Configuration is API and config-driven.

---

## Phase 1: Cache Engine

Delivers the two-layer cache engine with reverse index. Foundation for all subsequent phases.

1. Scaffold the Elixir umbrella project with `restdis_cache` as the first child app.
2. Implement per-tenant ETS table creation and lifecycle management via Cachex.
3. Implement per-tenant CubDB instance creation on local NVMe.
4. Expose internal API: `get/2`, `put/3`, `delete/2`, `flush_tenant/1`.
5. Implement three-layer read path: ETS lookup, CubDB fallback with ETS promotion, miss callback.
6. Implement reverse index in ETS: `(table, primary_key) -> MapSet of cache_keys`.
7. Update reverse index on every `put`. For single-row results, index the primary key. For array results, parse the JSON response and index every object's primary key.
8. Clean up orphaned reverse index entries on `delete` and TTL expiry via Cachex fallback hook.

**Completion criteria:**

- Cache engine passes property-based tests for get/put/delete across both layers.
- Reverse index correctly maps primary keys to cache keys and cleans up on eviction.
- CubDB survives simulated node restart and serves warm data on recovery.

**Risks:**

- CubDB write throughput under sustained load is unvalidated. Benchmark during this phase with target write rate (10k writes/sec per tenant). If CubDB bottlenecks, evaluate RocksDB NIF before proceeding to Phase 2.
- Reverse index write overhead scales linearly with array response size. A 1,000-object response creates 1,000 index entries on a single `put`. Document this trade-off and set a recommended maximum array size for cached responses.

---

## Phase 2: Redis Protocol Server

Delivers a Redis-compatible server that clients can connect to. Cache misses proxy to PostgREST.

1. Add `restdis_server` as the second child app.
2. Implement RESP protocol parser and TCP listener.
3. Implement core Redis commands: `PING`, `AUTH`, `GET`, `SET`, `MGET`, `DEL`, `TTL`, `EXISTS`.
4. Implement `PGRST.QUERY`: parse path, fetch from PostgREST via HTTP, cache result, return canonical cache key.
5. Implement `PGRST.POLICY`: update TTL, rewarm interval, or persist flag on existing cache entry.
6. Implement HTTP endpoint for PostgREST proxy with `SC-Cache`, `SC-Cache-TTL`, `SC-Cache-Rewarm` headers.
7. Implement cache key canonicalization: parse query parameters into a map, apply `:erlang.phash2/1`. Tenant config contains the API key used for PostgREST authz.
8. Add tenant config table to Postgres. Store default TTL, read replica URL, persist cap.
9. Implement `AUTH`: resolve tenant from Supabase API key via config Postgres. MVP ships unauthenticated. Wire the `AUTH` path but do not enforce.
10. Route PostgREST origin fetch to read replica when tenant config specifies one.

**Completion criteria:**

- `redis-cli` can connect, authenticate, and execute all supported commands.
- `PGRST.QUERY` returns cached PostgREST response on second call without hitting PostgREST.
- Canonical cache key is deterministic: identical query parameters in any order produce the same `phash2` value.
- HTTP endpoint behaves identically to RESP for cache operations.

**Risks:**

- RESP parsing edge cases with binary-safe bulk strings. Use an existing Elixir RESP library if available, or port from a proven implementation.

---

## Phase 3: WAL-Driven Cache Invalidation

Delivers automatic cache busting when tenant data changes. Queries are invalidated within seconds of a write.

1. Add `restdis_buster` as the third child app.
2. Add `:syn` as the cross-cluster process registry. Configure two scopes: `:wal` (unique registration for the WAL tailer singleton) and `:wal_fanout` (group registration keyed by AZ). Each node joins its scope on boot with AZ metadata read from runtime config (e.g. `RELEASE_AZ` env var). `libcluster` membership drives `:syn` node visibility; rely on `:syn`'s built-in netsplit resolution (last-write-wins by default; documented choice).
3. Implement the WAL tail as a singleton GenServer registered under `:syn` scope `:wal` with key `:wal_tailer`. Every node attempts to register on boot; `:syn` guarantees exactly one winner cluster-wide. Losers stay supervised and idle, ready to take over.
4. Connect to Postgres logical replication slot. Parse WAL events: table name, operation, old/new row data.
5. Extract primary key from WAL row data.
6. Broadcast WAL events to peers via `:syn.publish(:wal_fanout, {:az, az_name}, msg)`. One subscriber per AZ receives the event and re-broadcasts locally; bounds cross-AZ traffic to one message per AZ per event.
7. On DML event (INSERT, UPDATE, DELETE), look up reverse index for `(table, primary_key)`. Delete matching cache entries from ETS and CubDB.
8. On DDL event (DROP TABLE), flush all cache entries for the affected table.
9. Implement failover via `:syn` process monitoring. On WAL tailer exit, `:syn` emits an unregister event; idle candidates on other nodes race to re-register under `:wal` / `:wal_tailer`. The new owner reconnects to the replication slot from the last confirmed LSN persisted in Postgres.
10. Cache tenant config locally on each node. Implement config change listener that flushes affected table caches on config update.
11. Add metrics: WAL events processed/sec, invalidation latency, reverse index hit rate.

**Completion criteria:**

- A write to a tenant's Postgres table invalidates the corresponding cache entry within 2 seconds.
- GenSingleton failover completes within 5 seconds with no WAL events lost (at-least-once delivery from Postgres LSN resume).
- Killing the node currently holding `:wal`/`:wal_tailer` causes a peer to acquire the registration and resume WAL consumption within 5 seconds.
- `:syn` group membership for `:wal_fanout` reflects current cluster topology within 1 second of a node join/leave.
- Config change for a single table does not flush unrelated table caches.

**Risks:**

- GenSingleton failover has an event gap between crash and reconnection. Events confirmed but not broadcast are lost until LSN resumes. This is an unavoidable edge case in failure scenarios. For TTL-mode caches, stale data persists until TTL expiry. For replication mode (Phase 5), a reconciliation mechanism closes the gap post-failover. Documented.
- `:syn` netsplit resolution defaults to last-write-wins on rejoin. In a split-brain, both partitions may briefly run a WAL tailer and double-consume from the replication slot. Postgres rejects the second consumer (one slot, one connection), so the duplicate is bounded — but document it and rely on LSN-resume to avoid lost events.
- WAL volume from write-heavy tenants can overwhelm the buster's worker pool. Add backpressure and per-tenant rate limiting on worker spawns.

---

## Phase 4: Rewarm and Persistence

Delivers demand-driven cache warming and durable persistence for high-value entries.

1. Implement rewarm scheduler in `restdis_server`: on cache hit with rewarm interval, schedule re-query after the interval using a timer wheel per tenant.
2. On rewarm timer fire, re-execute PostgREST query and update ETS and CubDB.
3. If no request arrives within one rewarm interval after last re-query, evict the entry (unless `persist`).
4. Implement `persist` flag: entries skip rewarm eviction and write to CubDB with durable flag.
5. Enforce per-tenant persist cap of 50,000 keys. Reject writes exceeding the cap with a clear error.
6. Implement global disk cache replication: `persist` CubDB writes broadcast to peer nodes.
7. Add metrics: rewarm hit rate, rewarm PostgREST request volume, persist entry count per tenant.

**Completion criteria:**

- A cache entry with rewarm=10s is re-queried exactly once 10s after each read.
- An entry with no reads for one full rewarm interval is evicted.
- Persist entries survive node restart and are served from CubDB on recovery.
- Persist cap is enforced at 50,000 keys with an error, not silent eviction.

**Risks:**

- Rewarm scheduling at scale creates many timers. Use a single timer wheel or periodic sweep per tenant, not one `Process.send_after` per key.

---

## Phase 5: Table Replication

Delivers always-live KV datasets for latency-critical reads. Replicated tables stay current via WAL-triggered refresh.

1. Add `restdis_replicator` as the fourth child app.
2. Add replication config to tenant config table: table name, optional filter query, primary key column.
3. On subscription, fetch full result set from PostgREST with pagination. Store as KV pairs: `<table>:<primary_key> -> row`.
4. Register with `restdis_buster` for WAL events on replicated tables. Buster dispatches refresh (not invalidation) for replication-mode tables.
5. On WAL INSERT/UPDATE, re-fetch the affected row from PostgREST and update KV entry in place.
6. On WAL DELETE, remove the KV entry.
7. Clients access replicated data via standard Redis `GET <table>:<primary_key>`.
8. Implement post-failover reconciliation: after GenSingleton failover, replicator runs a full diff against PostgREST to catch events missed during the gap.

**Completion criteria:**

- `GET products:42` returns current row data within 2 seconds of a write.
- A replicated table with 10,000 rows loads fully on initial subscription.
- GenSingleton failover followed by reconciliation leaves zero stale entries.

**Risks:**

- Full table fetch on initial subscription is expensive for large tables. Paginate and rate-limit PostgREST requests.
- Reconciliation after failover is a full table scan. Stagger reconciliation across tenants to avoid PostgREST thundering herd.

---

## Phase 6: Cluster Distribution

Delivers multi-node deployment with consistent hash ring routing and global replication.

1. Integrate `libcluster` for cluster formation.
2. Implement consistent hash ring with virtual nodes keyed by tenant ID.
3. Route incoming requests to owning node. Serve locally if owner. Forward via Erlang distribution otherwise.
4. Handle hash ring rebalancing on node join/departure. Migrate tenant ETS and CubDB data to new owners.
5. Implement per-AZ fan-out for WAL broadcasts: `syn` group per AZ, one subscriber per AZ fans out locally.
6. Implement cross-region CubDB replication for `persist` entries via Erlang distribution.
7. Add fallback: if owning node is unreachable, proxy to PostgREST directly within 1 second.
8. Add metrics: cross-node request count, hash ring rebalance events, cross-region replication lag.

**Completion criteria:**

- A 3-node cluster routes requests to the correct owner by tenant ID.
- Node add/remove triggers rebalance with less than 5% key redistribution beyond minimum.
- Per-AZ fan-out delivers WAL events to all AZs within 500ms.
- Owning node failure falls through to PostgREST within 1 second.

**Risks:**

- Consistent hash ring without sufficient virtual nodes causes hotspots from uneven tenant sizes. Validate distribution uniformity with production tenant ID samples.
- Cross-region Erlang distribution adds latency. Persist replication is async. Brief windows of stale persist data after a write in another region. Acceptable.

---

## Phase 7: Production Hardening

Delivers monitoring, load testing, and operational readiness.

1. Add Prometheus metrics exporter: cache hit/miss rates per layer, ETS memory per tenant, CubDB disk usage per tenant, WAL processing latency, rewarm queue depth, RESP command latency histogram.
2. Add Grafana dashboard template.
3. Load test: 10,000 concurrent Redis connections across 100 tenants. Validate P99 < 1ms for cache hits.
4. Benchmark CubDB compaction under sustained mixed workload. Document compaction schedule.
5. Implement tenant resource limits: 500 MB ETS per tenant, 500 MB CubDB per tenant, 50k persist keys per tenant. Enforce with clear error responses.
6. Implement graceful degradation: ETS cap hit evicts LRU. CubDB cap hit evicts oldest non-persist entries.
7. Write operational runbook: deployment, scaling, failover, tenant onboarding, troubleshooting.
8. Wire Supabase API key auth enforcement on the `AUTH` command. Post-MVP gate.

**Completion criteria:**

- Grafana dashboard shows all key metrics for a running cluster.
- Load test passes with P99 < 1ms at target concurrency.
- Tenant caps (500 MB ETS, 500 MB CubDB, 50k persist keys) enforced with actionable error messages.
- Runbook reviewed and approved by on-call team.

---

## Resolved Questions

All questions closed. Decisions are inlined in the relevant sections above. Summary:

| #   | Question                   | Resolution                                                                                                                                  |
| --- | -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | RESP command subset        | Core set only: `GET`, `SET`, `MGET`, `DEL`, `TTL`, `EXISTS`, `PING`, `AUTH`, `PGRST.QUERY`, `PGRST.POLICY`. No `SUBSCRIBE`, `SCAN`, `KEYS`. |
| 2   | Cache key canonicalization | Parse query params into a map, apply `:erlang.phash2/1`. Tenant config holds PostgREST API key for authz.                                   |
| 3   | ETS memory budget          | 500 MB per tenant per node for MVP.                                                                                                         |
| 4   | DDL handling               | DML events invalidate affected rows via reverse index. DROP TABLE flushes all entries for that table.                                       |
| 5   | CubDB disk budget          | 500 MB per tenant per node for MVP.                                                                                                         |
| 6   | Redis layer auth           | Supabase API keys. MVP ships unauthenticated.                                                                                               |
| 7   | Read replica routing       | Tenant config specifies replica URL. No lag detection or failover.                                                                          |
| 8   | Persist entry cap          | 50,000 keys per tenant for MVP.                                                                                                             |
