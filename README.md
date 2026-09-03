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

## Quickstart

Run Restdis alongside a logical-replication-enabled Postgres with Docker Compose:

```sh
docker compose up --build
```

Or run the prebuilt image directly against your own Postgres:

```sh
docker run --rm \
  -e DATABASE_URL=ecto://postgres:postgres@host.docker.internal/restdis_dev \
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

## Usage

### RESP commands

| Command | Purpose |
| --- | --- |
| `PING` | Health check. |
| `AUTH <key>` | Authenticate using a Supabase API key (wired but not enforced yet). |
| `GET <key>` / `MGET <key>...` | Read one or more cached values. |
| `SET <key> <value>` | Write a value directly to the cache. |
| `DEL <key>` | Remove a cached value. |
| `TTL <key>` | Time remaining before a cached value expires. |
| `EXISTS <key>` | Check whether a key is cached. |
| `PGRST.QUERY <path> [TTL <seconds>] [REWARM <seconds>]` | Fetch `<path>` from PostgREST, cache the result, and return its canonical cache key. |
| `PGRST.POLICY <cache_key> [TTL <seconds>] [REWARM <seconds>] [PERSIST]` | Update an existing entry's TTL, rewarm interval, or persistence without re-fetching. |

### HTTP proxy

The same PostgREST caching behavior is available over HTTP. Send a normal PostgREST request
to Restdis and control caching with headers:

| Header | Purpose |
| --- | --- |
| `SC-Cache` | Enable caching for the request. |
| `SC-Cache-TTL` | TTL, in seconds, for the cached response. |
| `SC-Cache-Rewarm` | Rewarm interval, in seconds. |

### Configuration

Restdis is configured entirely through environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `DATABASE_URL` | required | Postgres URL for the repo and WAL replication connection |
| `RELEASE_COOKIE` | required for clustering | Erlang distribution cookie |
| `RELEASE_AZ` | `local` | Availability zone advertised to the `:wal_fanout` `syn` scope |
| `HTTP_PORT` | `4040` | HTTP endpoint port |
| `RESP_PORT` | `6380` | Redis RESP port |
| `RESP_LISTEN_IP` | `0.0.0.0` | RESP bind address (`:loopback` outside `:prod`) |
| `POOL_SIZE` | `10` | Repo pool size |
| `CACHE_DATA_DIR` | `/var/lib/restdis/cache` | CubDB disk cache root (mount a volume here) |
| `WAL_SLOT_NAME` | `restdis_slot` | Replication slot name |
| `WAL_PUBLICATION_NAME` | `restdis_pub` | Publication name |
| `MIGRATE_ON_BOOT` | `true` | Run migrations before starting the release |
| `REPLICATION_PAGE_SIZE` | `1000` | Rows per page when replicating a dataset |
| `REPLICATION_PAGE_DELAY_MS` | `50` | Delay between replication pages |
| `REPLICATION_RECONCILE_STAGGER_MS` | `1000` | Stagger between reconcile passes |
| `CLUSTER_DNS_QUERY` | unset | DNS name polled by `libcluster` to form the cluster; unset runs a single node |
| `CLUSTER_NODE_BASENAME` | `restdis` | Node basename used to build peer node names |
| `CLUSTER_POLL_INTERVAL_MS` | `5000` | DNS poll interval |

## Roadmap

Two RFCs describe planned work beyond the core caching proxy above. Neither is built yet;
both extend the same WAL-reading and caching foundation described in this README.

- **[`ELECTRIC_PRD.md`](ELECTRIC_PRD.md) — an Electric-compatible shape API.** Proposes
  serving [ElectricSQL](https://electric-sql.com)'s `GET /v1/shape` protocol directly from
  Restdis, so an application already using an Electric client library (`@electric-sql/client`,
  `@electric-sql/react`, and others) keeps working after changing only its base URL — giving
  clients live, partial, resumable copies of Postgres tables without running Electric as a
  separate service.
- **[`SUPABASE_INTEGRATION_PRD.md`](SUPABASE_INTEGRATION_PRD.md) — caching across the rest
  of the Supabase stack.** Proposes extending the same cache-and-invalidate mechanism to
  Realtime, Storage, Auth, and Edge Functions (not just PostgREST), plus a "prefer read
  replica" setting that applies to every Postgres-backed origin fetch.

## Learn more

- [`PRD.md`](PRD.md) — scope, architecture, and design decisions.
- [`DEVELOPMENT.md`](DEVELOPMENT.md) — building the Docker image, running the release, and
  local development setup.
- [`AGENT.md`](AGENT.md) — workflow and coding standards for contributors.
