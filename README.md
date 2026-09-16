# Restdis

Restdis is a caching proxy that sits in front of [PostgREST](https://postgrest.org) and
speaks the Redis wire protocol. It stores PostgREST responses in memory and on disk, so an
application that reads the same data repeatedly gets a sub-millisecond answer from Restdis
instead of a fresh round-trip to the database every time.

Caches normally go stale the moment the underlying data changes. Restdis avoids that by
reading Postgres's write-ahead log (WAL) — the internal record of every row Postgres writes —
and using it to invalidate or refresh only the cache entries a given change actually affects.
Applications never have to clear or manage the cache themselves.

Because Restdis speaks the Redis wire protocol, any existing Redis client library can connect
to it and use it exactly as it would use Redis, with no code changes.

## Features

- **Redis protocol server (RESP)** — connect with any standard Redis client. Supports `GET`,
  `SET`, `MGET`, `DEL`, `TTL`, `EXISTS`, `PING`, and `AUTH`.
- **HTTP proxy for PostgREST** — the same caching behavior over plain HTTP, with cache
  directives passed as headers.
- **Two-layer cache** — an in-memory ETS cache backed by a per-tenant CubDB store on disk, so
  warm data survives restarts.
- **Automatic WAL-driven invalidation** — a single WAL tailer per cluster watches for
  Postgres writes and busts or refreshes only the cache entries a write actually affects.
- **Two invalidation modes** — TTL mode expires and rewarms entries on demand; replication
  mode keeps entries continuously refreshed instead of expiring them.
- **Custom `PGRST.QUERY` / `PGRST.POLICY` commands** — fetch and cache a PostgREST query
  directly from Redis, then tune its TTL, rewarm interval, or persistence after the fact.
- **Always-live table replication** — mirror an entire PostgREST table as key/value pairs
  that stay current via WAL refresh, for latency-critical reads.
- **Multi-node clustering** — a consistent hash ring places each tenant on one owning node,
  with automatic forwarding and PostgREST fallback if that node is unreachable.
- **Electric-compatible shape API** — serves ElectricSQL's `GET /v1/shape` protocol directly
  from Restdis, so apps using `@electric-sql/client`, `@electric-sql/react`, or
  `@tanstack/electric-db-collection` work unchanged after pointing their `url` at Restdis. See
  [Electric compatibility](#electric-compatibility) below and [`ELECTRIC_PRD.md`](prds/ELECTRIC_PRD.md).
- **Caching across the rest of the Supabase stack [WIP]** — extend the same cache-and-invalidate
  mechanism to Realtime, Storage, Auth, and Edge Functions. See
  [`SUPABASE_INTEGRATION_PRD.md`](prds/SUPABASE_INTEGRATION_PRD.md).

## Quickstart

Run the prebuilt image against your own logical-replication-enabled Postgres:

```sh
docker run --rm \
  -e DATABASE_URL=postgres://postgres:postgres@localhost:5432/restdis_dev \
  -e RELEASE_COOKIE=some_secret_cookie \
  -p 4040:4040 -p 6380:6380 \
  restdis:latest
```

This exposes the HTTP proxy on port `4040` and the Redis (RESP) port on `6380`. Point a Redis
client at `6380` and start caching PostgREST queries:

```sh
redis-cli -p 6380 PGRST.QUERY /products?select=id,name TTL 60
```

The response includes the canonical cache key. A second call for the same query is served
from cache without hitting PostgREST.

The same caching also works over plain HTTP:

```sh
curl "http://localhost:4040/products?select=id,name" -H "SC-Cache: true"
```

## Usage

### RESP commands

| Command                                                                 | Purpose                                                                              |
| ----------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| `PING`                                                                  | Health check.                                                                        |
| `AUTH <key>`                                                            | Authenticate using a Supabase API key (wired but not enforced yet).                  |
| `GET <key>` / `MGET <key>...`                                           | Read one or more cached values.                                                      |
| `SET <key> <value>`                                                     | Write a value directly to the cache.                                                 |
| `DEL <key>`                                                             | Remove a cached value.                                                               |
| `TTL <key>`                                                             | Time remaining before a cached value expires.                                        |
| `EXISTS <key>`                                                          | Check whether a key is cached.                                                       |
| `PGRST.QUERY <path> [TTL <seconds>] [REWARM <seconds>]`                 | Fetch `<path>` from PostgREST, cache the result, and return its canonical cache key. |
| `PGRST.POLICY <cache_key> [TTL <seconds>] [REWARM <seconds>] [PERSIST]` | Update an existing entry's TTL, rewarm interval, or persistence without re-fetching. |

### HTTP proxy

The same PostgREST caching behavior is available over HTTP. Send a normal PostgREST request
to Restdis and control caching with headers:

| Header            | Purpose                                   |
| ----------------- | ----------------------------------------- |
| `SC-Cache`        | Enable caching for the request.           |
| `SC-Cache-TTL`    | TTL, in seconds, for the cached response. |
| `SC-Cache-Rewarm` | Rewarm interval, in seconds.              |

```sh
curl "http://localhost:4040/products?select=id,name" \
  -H "SC-Cache: true" \
  -H "SC-Cache-TTL: 60" \
  -H "SC-Cache-Rewarm: 30"
```

The first request fetches from PostgREST and caches the response; subsequent requests for the
same path and query string are served from cache until the TTL expires, and are rewarmed in
the background every 30 seconds while the entry stays hot.

### Configuration

Restdis is configured entirely through environment variables. See
[`docs/self-hosting.md`](docs/self-hosting.md) for the full list.

## Architecture

Restdis is an Elixir umbrella project split into bounded contexts, each owning one piece of
the system:

```
                              ┌──────────────┐
 Redis clients ───RESP───────▶│              │
                              │restdis_server│──── HTTP proxy ───▶ (apps below, via `restdis`)
 Electric clients ─HTTP──────▶│  (RESP +     │
 App clients ──────HTTP──────▶│   HTTP)      │
                              └──────┬───────┘
                                     │ reads
                                     ▼
                              ┌──────────────┐        ┌───────────────────┐
                              │   restdis    │◀───────│ restdis_electric   │
                              │ (ETS→CubDB→  │  pull   │ shape defs/handles │
                              │  PostgREST   │────────▶│ log, filter index, │
                              │   origin)    │  push   │ where-clause eval  │
                              └──────┬───────┘        └─────────▲──────────┘
                                     ▲                          │ push
                                     │ push                     │
                              ┌──────┴───────┐                  │
                              │restdis_buster│──────────────────┘
                              │ (one cluster-│
                              │  wide WAL    │
                              │  tailer)     │
                              └──────┬───────┘
                                     │ reads WAL
                                     ▼
                                 Postgres
                        (logical replication slot)

              restdis_replicator (always-live table replication)
                     and restdis_repo (Ecto/migrations)
                also depend on `restdis`, alongside the above.
```

| Application          | Owns                                                                                                                                                          |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `restdis`            | The three-layer cache (ETS, CubDB, PostgREST origin), the reverse index, tenant configuration, and cache keys. Depended on by every other app.                |
| `restdis_buster`     | The single cluster-wide WAL tailer. Reads the Postgres logical replication slot and dispatches decoded changes to invalidation, refresh, and shape targets.   |
| `restdis_repo`       | The Ecto repo and migrations.                                                                                                                                 |
| `restdis_replicator` | Always-live table replication (mirrors a full PostgREST table as key/value pairs kept current via WAL refresh).                                               |
| `restdis_electric`   | The Electric-compatible shape log: shape definitions, handles, the append-only log, the filter index, snapshotting, and `where`-clause evaluation. See below. |
| `restdis_server`     | The RESP (Redis protocol) server and the HTTP proxy/endpoint. The only app that terminates client connections.                                                |

A write lands in Postgres, is read once from the WAL by `restdis_buster`, and is fanned out
per availability zone to every node; each node then applies invalidation, refresh, or shape
appends locally. Reads go through `restdis_server`, which checks ETS, then CubDB, then falls
back to PostgREST, filling the faster layers as it goes. A consistent hash ring routes each
tenant to one owning node, with automatic forwarding and a PostgREST fallback if that node is
unreachable.

Dependencies point one way: `restdis_electric` depends only on `restdis`; `restdis_buster`
pushes changes into it and `restdis_server` reads from it, but neither is a dependency of it.

## Electric compatibility

Restdis serves ElectricSQL's shape-log protocol directly, so an application built against
`@electric-sql/client`, `@electric-sql/react`, `@tanstack/electric-db-collection`, or
`electric_client` (Hex) keeps working after changing only its `url` to point at Restdis — no
dependency changes, no fork.

- **`GET /v1/shape`** — takes `table`, `offset`, `handle`, `live`, `cursor`, `columns`,
  `where`, `params`, `replica`, `live_sse`, and `log`, and returns the same message shapes and
  `electric-*` headers Electric returns. Live updates are served by long-polling or
  Server-Sent Events; concurrent requests for the same `(tenant, handle, offset)` are
  collapsed into a single wait, so one Postgres write wakes every matching client with one
  append.
- **`DELETE /v1/shape`** — flushes a shape's log, gated by a per-tenant setting.
- **Consistency** — the initial snapshot is read from PostgREST page by page and reconciled
  against the WAL stream by LSN bracketing with idempotent operations, so no row is lost even
  though Restdis (unlike Electric) has no direct, privileged Postgres connection for
  snapshotting by default. A direct Postgres pool is supported per tenant for exact,
  duplicate-free snapshots and `log=changes_only`.
- **Filtering** — `where` clauses are parsed with a real SQL parser and evaluated against the
  documented subset Electric supports (comparisons, logical/arithmetic/bitwise operators,
  `LIKE`/`ILIKE`, array operators, `IN`, `BETWEEN`, a handful of functions, and constrained
  `IN (subquery)` forms). Anything outside that subset is rejected with `400` at subscribe
  time — Restdis never silently serves a shape it can't filter correctly.
- **Retention** — each shape keeps a configurable number of recent operations instead of an
  unbounded compacted log. A client resuming below that window gets a `409` with a new
  handle, which is the same recovery path Electric clients already implement, so this is
  observable but not incompatible.
- **Authentication** — Electric ships no authentication of its own, so a normal Electric
  deployment needs a hand-built proxy in front of it. Restdis reuses its existing per-tenant
  API-key authentication instead, with two modes: **gatekeeper**, where tenant configuration
  defines each shape by name and the client sends only protocol parameters (the default), and
  **open**, where the client supplies the shape definition within a configured column
  allow-list.


### Examples

```sh
curl "http://localhost:4040/v1/shape?table=products&offset=-1"
```

This returns a JSON array of `insert` messages, one per row, followed by an `up-to-date`
control message and an `electric-handle` header. Resume from where you left off by passing
that handle back along with the last offset you saw:

```sh
curl "http://localhost:4040/v1/shape?table=products&handle=<handle>&offset=<offset>&live=true"
```

With `live=true`, the request holds open until a matching Postgres write occurs or the request
times out, exactly as it would against a real Electric server.

## Learn more

- [`docs/self-hosting.md`](docs/self-hosting.md) — environment variable reference.
- [`PRD.md`](prds/PRD.md) — scope, architecture, and design decisions.
- [`DEVELOPMENT.md`](DEVELOPMENT.md) — building the Docker image, running the release, and
  local development setup.
