# Development

See `prds/PRD.md` for scope and architecture, and `AGENT.md` for the development workflow.

## Docker build

The image is a two-stage build: a `hexpm/elixir` builder that assembles the `restdis`
`mix release`, and a slim Debian runner that carries only the release.

```sh
docker build -t restdis:latest .
```

Toolchain versions are build args (`ELIXIR_VERSION`, `ERLANG_VERSION`, `DEBIAN_VERSION`) and
default to the versions pinned in `.mise.toml`.

## Cluster distribution

Tenants are placed on a consistent hash ring with 128 virtual nodes per node. The owning
node serves a tenant's cache; other nodes forward the operation over Erlang distribution
with a one second budget and, if the owner is unreachable, fetch from PostgREST directly.
Ring changes hand a tenant's `persist` entries to its new owner and drop the local copy.

## Release commands

`bin/server` migrates (unless `MIGRATE_ON_BOOT=false`) and starts the release. Migrations can
also be run on their own:

```sh
docker run --rm -e DATABASE_URL=... restdis:latest /app/bin/migrate
```

## Local Development

`docker-compose.yml` provides a local dev stack, alongside the `db`/`restdis` services used to smoke-test the production release image:

- `db` — Postgres 16 with `wal_level=logical` enabled (required for `restdis_buster`'s WAL tailer), exposed on `5432`, database `restdis_dev`.
- `app` — the umbrella app running under `mix` (not the release build), with `deps`/`_build`/`mix`/`hex` cached in named volumes so `mix deps.get` isn't re-run from scratch on every rebuild. Sets `POSTGRES_HOSTNAME=db` so `config/dev.exs` connects to the compose service instead of `localhost` (used when running `mix` directly on the host with a local Postgres), and `RESP_LISTEN_IP=0.0.0.0` so the RESP port is reachable from the host (`config/dev.exs` otherwise binds to `127.0.0.1` only).

Usage:

```sh
docker compose up app              # start db + the mix-based dev app
docker compose run --rm app mix test
docker compose exec app mix check
```

`mix test` needs the `restdis_test` database created and migrated first (`MIX_ENV=test POSTGRES_HOSTNAME=db mix ecto.create && mix ecto.migrate`, run inside the `app` container) since it isn't provisioned automatically.
