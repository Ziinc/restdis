# RFC: SupaCacher Core Library Extraction

Companion to `PRD.md`. Where the two disagree on cache or WAL behaviour, `PRD.md` wins;
this document only covers how that behaviour is packaged for reuse outside this repo.

## Problem

The multi-layer cache and the Postgres WAL follower are generally useful, but today they
are only usable as umbrella children of this application. Three things block reuse:

1. Configuration is read from the global application environment, so a host application
   cannot run an instance without owning our `:supa_cacher_cache` / `:supa_cacher_buster`
   config keys.
2. Process names and `:syn` scopes are hardcoded module atoms, so two instances collide
   and the library squats on the host's namespace.
3. The WAL follower calls `SupaCacherCache` and `SupaCacherRepo` directly, so neither half
   can be adopted alone.

## Scope

**In scope.** Extracting the cache engine and the WAL follower into a single published
package, `supa_cacher_core`, with Ecto as a required dependency and Oban-style migrations.

**Out of scope.** The RESP server, the HTTP endpoint, PostgREST fetching, rewarm
scheduling, and API-key auth. These stay in `supa_cacher_server` and remain application
concerns. No behaviour change to the cache or the WAL follower is in scope; this is a
packaging and dependency-inversion effort.

## Decisions

**One package, two supervision trees.** `supa_cacher_core` ships `SupaCacher.Cache` and
`SupaCacher.Wal` as independently mountable trees. A host may start either alone. They are
one package because both require Ecto, both read `tenants`, and splitting them would mean
two version counters, two prefix options, and a cross-package foreign key.

**Ecto is required, the repo is injected.** The library depends on `ecto_sql` but never
defines a repo. The host passes `repo:` at start time and the library uses the host's pool,
sandbox, and migration path. This is the Oban model.

**The library owns its tables.** `tenants`, `tenant_table_config` and `wal_checkpoint` move
into the library. `api_keys` stays in the application: it is auth policy, and it references
`tenants` rather than the other way round.

**Prefix is runtime, not `@schema_prefix`.** `@schema_prefix` is compile-time and cannot
carry a per-instance prefix, so schemas stay prefix-free and every repo call passes
`prefix:` from instance config. Raw SQL interpolates the prefix from validated config only.

**The publication is not a versioned migration.** `CREATE PUBLICATION` needs a
replication-privileged role and `FOR ALL TABLES` is the consumer's policy decision, so it
is exposed as a separate documented helper rather than folded into a migration version.

## Target API

```elixir
# In the host's supervision tree
{SupaCacher.Cache,
  repo: MyApp.Repo,
  prefix: "supa_cacher",
  data_dir: "/var/lib/supacacher/cache",
  origin: MyApp.Origin}

{SupaCacher.Wal,
  repo: MyApp.Repo,
  prefix: "supa_cacher",
  replication: [url: System.fetch_env!("DATABASE_URL")],
  slot_name: "my_slot",
  publication: "my_pub",
  handler: MyApp.WalHandler}
```

```elixir
# One host migration, written once
defmodule MyApp.Repo.Migrations.AddSupaCacher do
  use Ecto.Migration

  def up, do: SupaCacher.Migration.up(version: 1)
  def down, do: SupaCacher.Migration.down(version: 1)
end
```

---

## Phase 1: Versioned Migrations

Delivers the Oban-style migration surface. No runtime code changes; the umbrella keeps
running against its existing tables.

1. Add `SupaCacher.Migration` with `up/1`, `down/1` and `migrated_version/1`, accepting
   `:version`, `:prefix` and `:create_schema`.
2. Add `SupaCacher.Migrations.Postgres` as the stepwise runner that reads the recorded
   version and applies `V01..VN` in order, reversing for `down`.
3. Add `SupaCacher.Migrations.Postgres.V01` creating `tenants`, `tenant_table_config` and
   `wal_checkpoint`, collapsing the four existing table migrations minus `api_keys`.
4. Record the applied version in a table comment on `tenants`, read back by
   `migrated_version/1`.
5. Add `SupaCacher.Migration.create_publication/1` as a separate privileged helper,
   replacing `20260519000003_create_publication.exs`.
6. Replace the four umbrella migrations with a single migration calling
   `SupaCacher.Migration.up/1`, leaving `api_keys` as an application migration.

**Completion criteria:**

- `up` then `down` then `up` at every released version leaves the schema identical, under
  both the default and a custom prefix.
- `up/1` called twice is a no-op the second time.
- `mix ecto.reset` on the umbrella produces the same schema as before the change.

**Risks:**

- Collapsing existing migrations changes the schema-creation path for any deployed
  database. Verify the collapsed `V01` matches the current production schema column for
  column before merging.

## Phase 2: Migration Generator

Delivers the one-command install path for a host application.

1. Add `mix supa_cacher.gen.migration` emitting a timestamped host migration that calls
   `SupaCacher.Migration.up/1` at the current version.
2. Support `--prefix` and `--repo` flags on the generator.

**Completion criteria:**

- The generated file compiles and runs against a fresh database with no hand editing.

## Phase 3: Injected Repo and Prefix

Delivers per-instance configuration for everything that touches the database.

1. Resolve start options into an instance config store at boot, keyed by instance name.
2. Thread `repo:` and `prefix:` through `SupaCacherBuster.Infra.LsnStore`, replacing the
   hardcoded `SupaCacherRepo` at three call sites.
3. Thread `repo:` and `prefix:` through `SupaCacherBuster.TenantTableConfig.Cache`.
4. Move the `tenants` and `tenant_table_config` Ecto schemas into the library, prefix-free,
   with `prefix:` passed per query.
5. Read `default_ttl_s` and `persist_cap` from `tenants` through the injected repo, behind
   the tenant aggregate's config snapshot.
6. Delete the `tenant_config_lookup` MFA and its configuration.

**Completion criteria:**

- Two instances with different repos and prefixes run concurrently in one VM without
  interfering.
- `persist_cap` comes from the `tenants` row, with no hardcoded 50,000 fallback in
  `supa_cacher_cache.ex`.

**Risks:**

- The cache read path currently reaches tenant config synchronously. Adding a repo read
  behind it risks a latency regression on cold tenants; the config snapshot must be
  populated once at aggregate start, not per request.

## Phase 4: Handler Behaviour

Delivers a WAL follower that is usable without the cache.

1. Define a `handler` behaviour receiving decoded WAL events.
2. Replace the direct `SupaCacherCache.invalidate_by_row/3` and `flush_table/2` calls in
   `SupaCacherBuster.Worker` with a dispatch to the configured handler.
3. Move the `public.tenants` and `public.tenant_table_config` special-casing out of the
   worker into an application-level handler.
4. Ship the cache-invalidating handler as a library module the host can opt into.

**Completion criteria:**

- The WAL follower starts and delivers events with the cache application not loaded.

## Phase 5: Name Scoping and Explicit Start

Delivers safe co-existence with the host application.

1. Scope the cache registry, tenant supervisor, and dynamic supervisor names by instance.
2. Scope the `LsnStore` `:persistent_term` key and the `:syn` scopes by instance.
3. Make the singleton and fanout transports pluggable, with the `:syn` adapter optional and
   `libcluster` not a library dependency.
4. Remove `mod:` from both applications and expose `child_spec/1` instead.
5. Mount both trees explicitly from `supa_cacher_server`.

**Completion criteria:**

- Adding the library as a dependency starts no processes until the host mounts it.
- The full umbrella test suite passes with both trees started by name.

## Phase 6: Package and Publish

Delivers `supa_cacher_core` on Hex.

1. Move the library source to a top-level directory with its own `mix.exs` and lockfile,
   referenced from the umbrella as a `path:` dependency.
2. Move the library's tests, including the property-based cache tests, and give them a
   configuration independent of `config/config.exs`.
3. Add `package/0`, `docs/0`, licence, and `CHANGELOG.md`.
4. Add a CI job running the library's own `mix check` and test suite.
5. Publish `0.1.0`.

**Completion criteria:**

- The library's test suite passes from its own directory with the umbrella absent.
- Generated docs cover the two child specs, the migration module, and the handler
  behaviour.

---

## Open Questions

1. Package name: `supa_cacher_core`, or split the public module namespace from the package
   name (`supa_cache` / `SupaCache`)?
2. Should Phase 3 keep a read-through behaviour for tenant config as an escape hatch, or is
   the repo the only supported source?
3. Does the collapsed `V01` need to handle an existing database that already ran the four
   umbrella migrations, or is a clean-database assumption acceptable for `0.1.0`?
