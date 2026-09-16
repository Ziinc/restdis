# Restdis

## Problem

PostgREST queries from tenant applications hit the database on every request. High-read workloads repeat identical queries, generating unnecessary database load and latency. Restdis is a caching proxy that speaks the Redis protocol (so existing Redis client libraries work unchanged), caches PostgREST responses with configurable TTL and cache key control, invalidates or refreshes stale entries automatically via WAL, and supports always-live dataset replication for latency-critical reads.

## Architecture

Restdis is an Elixir umbrella application. Child apps:

| App | Responsibility |
| --- | --- |
| `restdis` | Standalone cache/WAL library (see `LIB_PRD.md`): the three-layer cache engine, reverse index, cluster hash ring, and the generic WAL follower. |
| `restdis_server` | RESP (Redis protocol) listener and HTTP endpoint for the PostgREST proxy. Parses commands, extracts tenant context, routes to the cache, proxies misses to PostgREST or a read replica, reads tenant config from Postgres, owns rewarm scheduling. |
| `restdis_buster` | WAL-follower application built on `restdis`'s `Restdis.Wal`: implements the cache-invalidation handler, per-AZ WAL fan-out, and the singleton WAL-tailer takeover. |
| `restdis_replicator` | Always-live KV datasets: initial full-table fetch from PostgREST, in-place updates driven by WAL change notifications, post-failover reconciliation. |
| `restdis_electric` | Electric-compatible shape API (see `ELECTRIC_PRD.md`). |
| `restdis_repo` | Shared Ecto repo and migrations owned by the application (as opposed to `restdis`'s own library-owned tables). |

## Three-layer cache

Reads resolve through three layers in order:

1. **ETS (hot).** One table per tenant. Key: `(tenant, {table_or_rpc_or_view, phash2(query_params_map)})`.
2. **CubDB (disk).** One instance per tenant, on local NVMe. Survives restarts.
3. **PostgREST (origin).** Populates both layers above. Routes to the tenant's configured read replica when one is set; no automatic failover or lag detection — if the replica is unreachable, the request fails.

Disk-cache entries written with `persist` replicate globally across the cluster.

## WAL-driven invalidation

A single `syn`-registered GenServer singleton tails the cluster's one Postgres logical-replication slot. On failure, another node takes over and resumes from the last confirmed LSN. Changes fan out per-AZ (one `syn` group per AZ, one subscriber fans out locally), bounding cross-AZ broadcast volume.

A reverse index maps `(table, primary_key) -> [cache_keys]`, covering both single-row and array query results — for array results, every object's primary key present in the cached response is indexed, so a 500-object response creates 500 reverse-index entries. A second, smaller index tracks which cache keys hold an array (list) response per table, independent of any particular primary key.

On UPDATE/DELETE, the reverse index resolves `(table, primary_key)` and only the matching cache entries (list or single-row) are deleted. On INSERT, the new row's primary key was never indexed, so instead every list-scoped cache entry for that table is invalidated via the second index; single-row cache entries are left untouched since an insert cannot affect them.

Two invalidation modes, configured per table in tenant config:

| Mode | On WAL change | TTL behavior |
| --- | --- | --- |
| TTL (default) | Cache entry is busted immediately, even if `persist` is set. | Entry expires at TTL; rewarm extends on demand. |
| Replication | Cache entry is refreshed in place, not deleted. | No TTL expiry; data stays live. |

`DROP TABLE` (via a Postgres event trigger) flushes all cache entries for the affected table. Tenant config changes invalidate and repopulate caches for the affected table.

## Redis protocol

`restdis_server` implements a much larger command set than a bare cache proxy: `PING`, `AUTH`, `GET`, `SET`, `MGET`, `DEL`, `TTL`, `EXISTS`, `INCR`, `DECR`, `INCRBY`, `DECRBY`, `EXPIRE`, `PEXPIRE`, `PERSIST`, `SETNX`, `GETSET`, `GETDEL`, `APPEND`, `STRLEN`, `RENAME`, `RENAMENX`, `DBSIZE`, `COPY`. `AUTH` is required before any other command except `PING`/`AUTH` itself (`NOAUTH` is returned otherwise) and resolves the connection's tenant from a Supabase API key. `SUBSCRIBE`, `SCAN`, and `KEYS` are not implemented; there is no Redis Cluster protocol (`MOVED`/`ASK`) or Sentinel support.

Two custom commands extend the protocol:

- `PGRST.QUERY <path> [TTL <seconds>] [REWARM <seconds>]` — fetches from PostgREST, caches the result, returns the canonical cache key.
- `PGRST.POLICY <cache_key> [TTL <seconds>] [REWARM <seconds>] [PERSIST]` — updates cache policy on an existing entry without re-fetching.

Both are also reachable over the HTTP endpoint via `SC-Cache`, `SC-Cache-TTL`, and `SC-Cache-Rewarm` headers.

`PERSIST` on a key extends its TTL to the tenant's `max_ttl_s` ceiling (rather than clearing it entirely, since every entry is still subject to the disk cache's own eviction/cap accounting) and writes it through to disk.

## Rewarm and persistence

On a cache hit against an entry with a rewarm interval set, `restdis_server` schedules a re-query after that interval; if no request arrives within one interval of the last re-query, the entry is evicted unless `persist` is set. `persist` entries skip rewarm eviction. Each tenant has a `persist_cap` (default 50,000 keys); writes beyond the cap return `{:error, :persist_cap}`, surfaced to RESP clients as `ERR persist cap reached for tenant` rather than silent eviction.

## Table replication

`restdis_replicator` mirrors a whole PostgREST table (optionally filtered) as individual `<table>:<primary_key>` KV pairs, fetched page by page on initial subscription (`REPLICATION_PAGE_SIZE`, `REPLICATION_PAGE_DELAY_MS`) and kept current by WAL-driven refresh (insert/update re-fetches the row; delete removes the KV entry) rather than invalidation. After a WAL-tailer failover, a reconciler runs a full diff against PostgREST (staggered per `REPLICATION_RECONCILE_STAGGER_MS`) to catch anything missed during the gap. Clients read replicated data with a normal `GET <table>:<primary_key>`.

## Cluster distribution

Nodes form a cluster via `libcluster`, discovered by DNS (`CLUSTER_DNS_QUERY`; unset runs a single node). Tenants are placed on a consistent hash ring (`Restdis.Cache.Cluster.HashRing`) with 128 virtual nodes per node, so tenant ownership stays even and a join/leave only moves the tenants hashing into the affected arcs. The owning node serves a tenant's cache; other nodes forward the request over Erlang distribution, falling through to a direct PostgREST fetch if the owner is unreachable. Ring changes hand a tenant's `persist` entries to the new owner and drop the local copy.

## Tenant configuration

Tenant config lives in Postgres (`tenants`, `tenant_table_config`, `api_keys`) and includes: default TTL, `max_ttl_s`, `persist_cap`, read replica URL, per-table invalidation mode, and (for `restdis_electric`) `auth_mode` and shape definitions. Authentication resolves a Supabase API key to a tenant via this config, both for RESP `AUTH` and the HTTP endpoint's auth plug.

## Out of scope

Full Redis command surface beyond the set above; Redis Cluster protocol and Sentinel; caching of PostgREST mutations (`POST`/`PATCH`/`DELETE`); multi-tenant database provisioning (tenant databases already exist); a dashboard UI (configuration is API/config-driven).
