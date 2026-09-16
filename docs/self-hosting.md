# Self-hosting

## Docker Compose

[`docker-compose.yml`](../docker-compose.yml) runs Restdis alongside a
logical-replication-enabled Postgres:

```sh
docker compose up --build
```

Use it as a reference for wiring up your own deployment — the Postgres service configuration,
`RESTDIS_DATABASE_URL`, and the ports Restdis exposes all mirror what you'd set up against your own
database.

## Configuration

Restdis is configured entirely through environment variables.

| Variable                           | Default                  | Purpose                                                                       |
| ----------------------------------- | ------------------------ | ----------------------------------------------------------------------------- |
| `RESTDIS_DATABASE_URL`                     | required                 | Postgres URL for the repo and WAL replication connection                      |
| `RELEASE_COOKIE`                   | required for clustering  | Erlang distribution cookie                                                    |
| `RESTDIS_RELEASE_AZ`                       | `local`                  | Availability zone advertised to the `:wal_fanout` `syn` scope                 |
| `RESTDIS_HTTP_PORT`                        | `4040`                   | HTTP endpoint port                                                            |
| `RESTDIS_RESP_PORT`                        | `6380`                   | Redis RESP port                                                               |
| `RESTDIS_RESP_LISTEN_IP`                   | `0.0.0.0`                | RESP bind address (`:loopback` outside `:prod`)                               |
| `RESTDIS_POOL_SIZE`                        | `10`                     | Repo pool size                                                                |
| `RESTDIS_CACHE_DATA_DIR`                   | `/var/lib/restdis/cache` | CubDB disk cache root (mount a volume here)                                   |
| `RESTDIS_WAL_SLOT_NAME`                    | `restdis_slot`           | Replication slot name                                                         |
| `RESTDIS_WAL_PUBLICATION_NAME`             | `restdis_pub`            | Publication name                                                              |
| `RESTDIS_MIGRATE_ON_BOOT`                  | `true`                   | Run migrations before starting the release                                    |
| `RESTDIS_REPLICATION_PAGE_SIZE`            | `1000`                   | Rows per page when replicating a dataset                                      |
| `RESTDIS_REPLICATION_PAGE_DELAY_MS`        | `50`                     | Delay between replication pages                                               |
| `RESTDIS_REPLICATION_RECONCILE_STAGGER_MS` | `1000`                   | Stagger between reconcile passes                                              |
| `RESTDIS_CLUSTER_DNS_QUERY`                | unset                    | DNS name polled by `libcluster` to form the cluster; unset runs a single node |
| `RESTDIS_CLUSTER_NODE_BASENAME`            | `restdis`                | Node basename used to build peer node names                                   |
| `RESTDIS_CLUSTER_POLL_INTERVAL_MS`         | `5000`                   | DNS poll interval                                                             |
