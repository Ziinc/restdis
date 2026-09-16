# Redis-protocol demo

Walks through Restdis's Redis wire protocol (RESP) directly with
`redis-cli`, against a lightweight stack: just Postgres, PostgREST, and
Restdis (`docker-compose.yml` in this directory) - no GoTrue, Prometheus, or
Grafana, since this demo never touches Auth or a dashboard. Complements
`demos/supabase/demo.sh`, which drives the same cache through Restdis's HTTP
endpoint against the full Supabase stack.

## Running locally

```sh
cd demos/redis
./demo.sh              # brings the stack up, then walks through it
./demo.sh --no-up      # stack already running, skip straight to the walkthrough
DEMO_AUTOPLAY=1 ./demo.sh   # no keypresses; sleeps between steps instead
```

Requires `redis-cli`, `curl`, and `docker compose` on `PATH`.

Tear down with:

```sh
docker compose down -v
```

## Ports

| Service | Port (host) |
| --- | --- |
| restdis | 4041 (HTTP), 6381 (RESP) |
| db | 5433 |
| rest | 3000 |

Same offsets as `demos/supabase/docker-compose.yml` (so the two stacks share
port numbers and shouldn't be run side by side), but distinct from the root
`docker-compose.yml`'s ports (4040, 6380, 5432).

## What it covers

Unauthenticated `NOAUTH` rejection, `AUTH` with a Supabase API key, plain
Redis commands (`SET`/`GET`/`EXPIRE`/`TTL`), `PGRST.QUERY` and
`PGRST.POLICY` over RESP, `PERSIST` (capped at the tenant's `max_ttl_s`), and
the rewarm interval on a `PGRST.QUERY` entry - see `prds/PRD.md` for the
underlying cache and rewarm semantics.
