# SupaCacher

See `PRD.md` for scope and architecture, and `AGENT.md` for the development workflow.

## Docker build

The image is a two-stage build: a `hexpm/elixir` builder that assembles the `supacacher`
`mix release`, and a slim Debian runner that carries only the release.

```sh
docker build -t supacacher:latest .
```

Toolchain versions are build args (`ELIXIR_VERSION`, `ERLANG_VERSION`, `DEBIAN_VERSION`) and
default to the versions pinned in `.mise.toml`.

## Running

```sh
docker run --rm \
  -e DATABASE_URL=ecto://postgres:postgres@host.docker.internal/supa_cacher_dev \
  -e RELEASE_COOKIE=some_secret_cookie \
  -p 4040:4040 -p 6380:6380 \
  supacacher:latest
```

Or bring up the app plus a logical-replication-enabled Postgres:

```sh
docker compose up --build
```

### Environment

| Variable | Default | Purpose |
| --- | --- | --- |
| `DATABASE_URL` | required | Postgres URL for the repo and WAL replication connection |
| `RELEASE_COOKIE` | required for clustering | Erlang distribution cookie |
| `RELEASE_AZ` | `local` | Availability zone advertised to the `:wal_fanout` `syn` scope |
| `HTTP_PORT` | `4040` | HTTP endpoint port |
| `RESP_PORT` | `6380` | Redis RESP port |
| `RESP_LISTEN_IP` | `0.0.0.0` | RESP bind address (`:loopback` outside `:prod`) |
| `POOL_SIZE` | `10` | Repo pool size |
| `CACHE_DATA_DIR` | `/var/lib/supacacher/cache` | CubDB disk cache root (mount a volume here) |
| `WAL_SLOT_NAME` | `supacacher_slot` | Replication slot name |
| `WAL_PUBLICATION_NAME` | `supacacher_pub` | Publication name |
| `MIGRATE_ON_BOOT` | `true` | Run migrations before starting the release |
| `REPLICATION_PAGE_SIZE` | `1000` | Rows per page when replicating a dataset |
| `REPLICATION_PAGE_DELAY_MS` | `50` | Delay between replication pages |
| `REPLICATION_RECONCILE_STAGGER_MS` | `1000` | Stagger between reconcile passes |
| `CLUSTER_DNS_QUERY` | unset | DNS name polled by `libcluster` to form the cluster; unset runs a single node |
| `CLUSTER_NODE_BASENAME` | `supacacher` | Node basename used to build peer node names |
| `CLUSTER_POLL_INTERVAL_MS` | `5000` | DNS poll interval |

### Cluster distribution

Tenants are placed on a consistent hash ring with 128 virtual nodes per node. The owning
node serves a tenant's cache; other nodes forward the operation over Erlang distribution
with a one second budget and, if the owner is unreachable, fetch from PostgREST directly.
Ring changes hand a tenant's `persist` entries to its new owner and drop the local copy.

### Release commands

`bin/server` migrates (unless `MIGRATE_ON_BOOT=false`) and starts the release. Migrations can
also be run on their own:

```sh
docker run --rm -e DATABASE_URL=... supacacher:latest /app/bin/migrate
```
