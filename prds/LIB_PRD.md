# Restdis core library

Companion to `PRD.md`. Where the two disagree on cache or WAL behavior, `PRD.md` wins; this document covers how that behavior is packaged for reuse outside this repo.

## Problem

The multi-layer cache and the Postgres WAL follower are generally useful beyond this application. Packaging them as a standalone library required: reading configuration from instance options rather than the global application environment, scoping process names and `:syn` scopes per instance rather than hardcoding module atoms, and having the WAL follower talk to a repo/handler passed in at start time rather than calling application modules directly.

## What shipped

`apps/restdis` (module namespace `Restdis`) is a standalone Mix project, `path:`-dependency-only, depending on no other umbrella application. It ships two independently mountable supervision trees, `Restdis.Cache` and `Restdis.Wal`, both started via `child_spec/1` — the library declares no `application` callback and starts no processes until a host mounts it.

```elixir
{Restdis.Cache,
  repo: MyApp.Repo,
  prefix: "restdis",
  data_dir: "/var/lib/restdis/cache",
  origin: MyApp.Origin}

{Restdis.Wal,
  repo: MyApp.Repo,
  prefix: "restdis",
  replication: [url: System.fetch_env!("DATABASE_URL")],
  slot_name: "my_slot",
  publication: "my_pub",
  handler: MyApp.WalHandler}
```

```elixir
defmodule MyApp.Repo.Migrations.AddRestdis do
  use Ecto.Migration

  def up, do: Restdis.Migration.up(version: 1)
  def down, do: Restdis.Migration.down(version: 1)
end
```

- **Ecto is required; the repo is injected.** The library depends on `ecto_sql` but defines no repo of its own — the host passes `repo:` (and `prefix:`) at start time, so the library reads/writes through the host's pool, sandbox, and migration path (the Oban model). Two instances with different repos/prefixes can run concurrently in one VM.
- **Owned tables.** `tenants`, `tenant_table_config`, and `wal_checkpoint` are library-owned, prefix-free schemas (prefix passed per query, since `@schema_prefix` is compile-time and can't carry a per-instance value). `api_keys` stays with the application, since it's auth policy that references `tenants`.
- **Versioned migrations.** `Restdis.Migration.up/1` / `down/1` / `migrated_version/1` run a stepwise runner (`Restdis.Migrations.Postgres`) over versioned modules, recording the applied version in a table comment on `tenants`. `Restdis.Migration.create_publication/1` is a separate helper for `CREATE PUBLICATION`, since it needs a replication-privileged role and `FOR ALL TABLES` is a consumer policy decision, not something to bake into a migration.
- **Migration generator.** `mix restdis.gen.migration` (with `--prefix` and `--repo`) emits a host migration file that calls `Restdis.Migration.up/1` at the current version.
- **WAL follower handler behaviour.** The library's WAL follower decodes replication events and dispatches to a `handler:` module the host supplies, rather than calling cache-invalidation code directly. The application's WAL app (`restdis_buster`) implements that handler (`RestdisBuster.CacheHandler`) to invalidate/refresh the cache and to special-case `tenants`/`tenant_table_config` changes; the library itself has no knowledge of cache invalidation semantics.
- **Boundary enforcement.** `apps/restdis/mix.exs` defines a `check.boundary` Mix task driven by an `@umbrella_namespaces` list (`RestdisServer`, `RestdisBuster`, `RestdisRepo`, `RestdisElectric`); the build fails if any library module references one of those namespaces, keeping the dependency-inversion real rather than aspirational.
- **Name scoping.** Cache registries, tenant supervisors, and `:syn`/singleton/fanout scopes are keyed by instance, so a host can run more than one instance without collision.

## Scope

**In scope:** the cache engine (`Restdis.Cache`) and the WAL follower (`Restdis.Wal`), their migrations, and the generator — packaged so a host application other than this one could depend on `apps/restdis` by path and use them standalone.

**Out of scope:** the RESP server, the HTTP endpoint, PostgREST fetching, rewarm scheduling, and API-key auth. Those remain in `restdis_server` as application concerns. Publishing to Hex is out of scope; the application consumes the library by path, and the two move together in one repository with no separate release step.

Tenant configuration has no read-through hook or escape hatch: a consumer of the library runs the generated migration and populates `tenants` directly through its own repo.
