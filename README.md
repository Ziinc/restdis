# Restdis

**The caching layer for [Supabase](https://supabase.com). Cached reads from
[PostgREST](https://postgrest.org) that never go stale, through the Redis or Electric client you
already use.**

Restdis sits between your app and PostgREST. It keeps responses in memory and on disk, and
answers repeat reads from memory instead of sending them back to Postgres.

Most caches serve old data until a TTL runs out or someone clears them. Restdis reads the
Postgres write-ahead log (WAL), the record of every row Postgres writes, so it sees each write
as it lands. It then clears or refreshes only the entries that write touched. You write no
invalidation code.

Restdis speaks the Redis protocol and the [ElectricSQL](https://electric-sql.com) sync
protocol. Point any Redis client at it, or any Electric client such as
[TanStack DB](https://tanstack.com/db), and it works: no new library, no code changes.

## What you get

- **Use any Redis client.** Restdis serves the Redis protocol (RESP) and supports `GET`, `SET`,
  `MGET`, `DEL`, `TTL`, `EXISTS`, `PING`, and `AUTH`.
- **Or use plain HTTP.** Pass a PostgREST query path to Restdis's `/pgrst/query` endpoint and
  get the cached response back.
- **Keep a warm cache through restarts.** Each read checks memory (ETS) first, then a
  per-tenant disk store (CubDB), then PostgREST.
- **Never clear the cache by hand.** One WAL reader per cluster watches every Postgres write
  and updates only the entries that write affects.
- **Choose how entries stay fresh.** TTL mode expires entries and rewarms them on the next
  read. Replication mode refreshes them in place and never expires them.
- **Cache a PostgREST query from Redis.** `PGRST.QUERY` fetches and caches a query in one
  command. `PGRST.POLICY` changes its TTL, rewarm interval, or persistence later.
- **Mirror a whole table.** Replicate a PostgREST table as key/value pairs that the WAL keeps
  current, for your hottest reads.
- **Scale across nodes.** A consistent hash ring gives each tenant one owning node. Other nodes
  forward to it, and fall back to PostgREST if it is down.
- **Run Electric apps unchanged.** Restdis serves ElectricSQL's `GET /v1/shape` protocol.
  Apps built on `@electric-sql/client`, `@electric-sql/react`, or
  `@tanstack/electric-db-collection` work after you change one `url`. See
  [Electric compatibility](#electric-compatibility) and [`ELECTRIC_PRD.md`](prds/ELECTRIC_PRD.md).
- **Coming: the rest of Supabase [WIP].** The same cache and invalidation for Realtime,
  Storage, Auth, and Edge Functions. See
  [`SUPABASE_INTEGRATION_PRD.md`](prds/SUPABASE_INTEGRATION_PRD.md).

## See it work

Each demo runs a stock client on the left. On the right are the Restdis request log and the
Postgres statement log, so you can count which reads reach the database. Source and
re-recording steps: [`demos/videos`](demos/videos).

### supabase-js with TanStack Query

An ordinary `supabase.from("products").select()` call inside `useQuery`. A small fetch adapter
sends its reads to Restdis. The console under the app shows each request, its `rd-cache`
header, and the response time. Repeat fetches are cache hits that Postgres never sees. A write
from another service evicts the entry through the WAL, and the next fetch gets the new price.

![supabase-js with TanStack Query demo](docs/demos/query.gif)

### TanStack DB over the Electric protocol

Two TanStack DB clients sync the same shape from Restdis with
`@tanstack/electric-db-collection`. The console shows each client's live poll held open on
Restdis, and the inserts, updates and deletes each poll delivers. Another user inserts,
renames, completes, bulk-inserts and deletes todos; both clients follow every change.
Restdis reads each new or changed row once by primary key, and deletes need no read.

![TanStack DB demo](docs/demos/db.gif)

### Any Redis client

ioredis, with its default settings, caches a PostgREST query with `PGRST.QUERY` and reads it
with plain `GET`s. A write evicts the key, and one more query refreshes it.

![Redis client demo](docs/demos/redis.gif)

## Quickstart

Build the image and run it against any Postgres with logical replication turned on
(`wal_level=logical`):

```sh
docker build -t restdis .
docker run --rm \
  --add-host=host.docker.internal:host-gateway \
  -e DATABASE_URL=postgres://postgres:postgres@host.docker.internal:5432/restdis_dev \
  -e RELEASE_COOKIE=some_secret_cookie \
  -p 4040:4040 -p 6380:6380 \
  restdis
```

`host.docker.internal` is how the container reaches services on your machine. Restdis creates
its own tables on boot. Then register a tenant, the PostgREST it fronts, and an API key for it:

```sql
INSERT INTO tenants (tenant_id, pgrst_base_url, pgrst_api_key, inserted_at, updated_at)
VALUES ('my-tenant', 'http://host.docker.internal:3000', '<postgrest-key>', now(), now());

INSERT INTO api_keys (api_key, tenant_id, inserted_at, updated_at)
VALUES ('sk_my_key', 'my-tenant', now(), now());
```

The HTTP endpoint listens on port `4040` and the Redis (RESP) server on `6380`. Point a Redis
client at `6380`, authenticate with the API key, and cache a PostgREST query:

```sh
redis-cli -p 6380 -a sk_my_key PGRST.QUERY 'products?select=id,name' TTL 60
```

Restdis returns the cache key. Read it with `GET`. The next call for the same query comes from
the cache and never reaches PostgREST.

Plain HTTP works too:

```sh
curl "http://localhost:4040/pgrst/query?path=products%3Fselect%3Did%2Cname" \
  -H "Authorization: Bearer sk_my_key"
```

## Usage

### RESP commands

| Command                                                                 | Purpose                                                                              |
| ----------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| `PING`                                                                  | Health check.                                                                        |
| `AUTH <key>`                                                            | Authenticate with a tenant API key. Every command except `PING` and `AUTH` needs it. |
| `GET <key>` / `MGET <key>...`                                           | Read one or more cached values.                                                      |
| `SET <key> <value>`                                                     | Write a value directly to the cache.                                                 |
| `DEL <key>`                                                             | Remove a cached value.                                                               |
| `TTL <key>`                                                             | Time remaining before a cached value expires.                                        |
| `EXISTS <key>`                                                          | Check whether a key is cached.                                                       |
| `PGRST.QUERY <path> [TTL <seconds>] [REWARM <seconds>]`                 | Fetch `<path>` from PostgREST, cache the result, and return its canonical cache key. |
| `PGRST.POLICY <cache_key> [TTL <seconds>] [REWARM <seconds>] [PERSIST]` | Update an existing entry's TTL, rewarm interval, or persistence without re-fetching. |
| `QUIT`                                                                  | Reply `OK` and close the connection.                                                 |

### HTTP endpoint

Every route except `/health` and `/metrics` needs `Authorization: Bearer <api key>`.

| Route                                 | Purpose                                                                                       |
| ------------------------------------- | --------------------------------------------------------------------------------------------- |
| `GET /pgrst/query?path=<query>`       | Return the cached response for a URL-encoded PostgREST query, fetching it on a miss.          |
| `POST /pgrst/policy`                  | Change a cached entry's policy. JSON body: `key`, and any of `ttl_s`, `rewarm`, `persist`.    |
| `GET /v1/shape`, `DELETE /v1/shape`   | Electric shape protocol. See [Electric compatibility](#electric-compatibility).               |
| `GET /health`, `GET /metrics`         | Liveness check and Prometheus metrics.                                                        |

`/pgrst/query` reports what happened in its response headers:

| Header            | Value                                                                        |
| ----------------- | ---------------------------------------------------------------------------- |
| `sc-cache`        | `MISS` (fetched from PostgREST), `HIT` (from cache), or `BYPASS` (fallback). |
| `sc-cache-ttl`    | Seconds until the entry expires.                                             |
| `sc-cache-rewarm` | On a hit, `scheduled` if the entry has a rewarm interval, otherwise `none`.  |

```sh
curl "http://localhost:4040/pgrst/query?path=products%3Fselect%3Did%2Cname" \
  -H "Authorization: Bearer sk_my_key"

curl -X POST http://localhost:4040/pgrst/policy \
  -H "Authorization: Bearer sk_my_key" \
  -H "Content-Type: application/json" \
  -d '{"key": "pgrst:t:products:38301388", "ttl_s": 60, "rewarm": 30}'
```

The first request goes to PostgREST and Restdis caches the response. Later requests for the
same query come from the cache until the TTL runs out. With `rewarm` set, Restdis refreshes the
entry in the background on that interval while it stays in use.

### Configuration

You configure Restdis with environment variables only. See
[`docs/self-hosting.md`](docs/self-hosting.md) for the full list.

## Architecture

Restdis is an Elixir umbrella project. Each app owns one part of the system:

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

**Writes.** A write lands in Postgres. `restdis_buster` reads it once from the WAL and sends
it to every node, one copy per availability zone. Each node then invalidates, refreshes, or
appends to shapes locally.

**Reads.** `restdis_server` checks ETS, then CubDB, then PostgREST, and fills the faster layers
on the way back. A consistent hash ring routes each tenant to one owning node. Other nodes
forward to it, and fall back to PostgREST if it is down.

**Dependencies point one way.** `restdis_electric` depends only on `restdis`. `restdis_buster`
pushes changes into it and `restdis_server` reads from it, but it depends on neither.

## Electric compatibility

Restdis serves ElectricSQL's shape-log protocol. Apps built on `@electric-sql/client`,
`@electric-sql/react`, `@tanstack/electric-db-collection`, or `electric_client` (Hex) keep
working when you point their `url` at Restdis. No dependency changes, no fork.

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

A table served as a shape needs `REPLICA IDENTITY FULL`, so the WAL carries every column of
each changed row. In the default **gatekeeper** mode, define each shape by name first:

```sql
ALTER TABLE products REPLICA IDENTITY FULL;

INSERT INTO shape_definitions (tenant_id, name, "table", inserted_at, updated_at)
VALUES ('my-tenant', 'products', 'products', now(), now());
```

Then request it by name:

```sh
curl -i "http://localhost:4040/v1/shape?shape=products&offset=-1" \
  -H "Authorization: Bearer sk_my_key"
```

This returns a JSON array of `insert` messages, one per row, followed by an `up-to-date`
control message, with `electric-handle` and `electric-offset` headers. Resume from where you
left off by passing both back:

```sh
curl "http://localhost:4040/v1/shape?shape=products&handle=<handle>&offset=<offset>&live=true" \
  -H "Authorization: Bearer sk_my_key"
```

With `live=true`, the request holds open until a matching Postgres write occurs or the request
times out, exactly as it would against a real Electric server. In **open** mode
(`auth_mode = 'open'` on the tenant), the client passes `table=products` instead of `shape`.

## Learn more

- [`docs/self-hosting.md`](docs/self-hosting.md) — environment variable reference.
- [`PRD.md`](prds/PRD.md) — scope, architecture, and design decisions.
- [`DEVELOPMENT.md`](DEVELOPMENT.md) — building the Docker image, running the release, and
  local development setup.
