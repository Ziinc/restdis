# Self-hosting

## Docker Compose

[`docker-compose.yml`](../docker-compose.yml) runs Restdis alongside a
logical-replication-enabled Postgres:

```sh
docker compose up --build
```

Use it as a reference for wiring up your own deployment — the Postgres service configuration,
`DATABASE_URL`, and the ports Restdis exposes all mirror what you'd set up against your own
database.

## Configuration

Restdis is configured entirely through environment variables.

| Variable                           | Default                  | Purpose                                                                       |
| ----------------------------------- | ------------------------ | ----------------------------------------------------------------------------- |
| `DATABASE_URL`                     | required                 | Postgres URL for the repo and WAL replication connection                      |
| `RELEASE_COOKIE`                   | required for clustering  | Erlang distribution cookie                                                    |
| `RELEASE_AZ`                       | `local`                  | Availability zone advertised to the `:wal_fanout` `syn` scope                 |
| `HTTP_PORT`                        | `4040`                   | HTTP endpoint port                                                            |
| `RESP_PORT`                        | `6380`                   | Redis RESP port                                                               |
| `RESP_LISTEN_IP`                   | `0.0.0.0`                | RESP bind address (`:loopback` outside `:prod`)                               |
| `POOL_SIZE`                        | `10`                     | Repo pool size                                                                |
| `CACHE_DATA_DIR`                   | `/var/lib/restdis/cache` | CubDB disk cache root (mount a volume here)                                   |
| `WAL_SLOT_NAME`                    | `restdis_slot`           | Replication slot name                                                         |
| `WAL_PUBLICATION_NAME`             | `restdis_pub`            | Publication name                                                              |
| `MIGRATE_ON_BOOT`                  | `true`                   | Run migrations before starting the release                                    |
| `REPLICATION_PAGE_SIZE`            | `1000`                   | Rows per page when replicating a dataset                                      |
| `REPLICATION_PAGE_DELAY_MS`        | `50`                     | Delay between replication pages                                               |
| `REPLICATION_RECONCILE_STAGGER_MS` | `1000`                   | Stagger between reconcile passes                                              |
| `CLUSTER_DNS_QUERY`                | unset                    | DNS name polled by `libcluster` to form the cluster; unset runs a single node |
| `CLUSTER_NODE_BASENAME`            | `restdis`                | Node basename used to build peer node names                                   |
| `CLUSTER_POLL_INTERVAL_MS`         | `5000`                   | DNS poll interval                                                             |
