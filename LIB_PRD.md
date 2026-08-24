# RFC: Restdis Core Library Extraction

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
package, `restdis`, with Ecto as a required dependency and Oban-style migrations.

**Out of scope.** The RESP server, the HTTP endpoint, PostgREST fetching, rewarm
scheduling, and API-key auth. These stay in `supa_cacher_server` and remain application
concerns. No behaviour change to the cache or the WAL follower is in scope; this is a
packaging and dependency-inversion effort.

## Decisions

**One package, two supervision trees.** `restdis` ships `Restdis.Cache` and
`Restdis.Wal` as independently mountable trees. A host may start either alone. They are
one package because both require Ecto, both read `tenants`, and splitting them would mean
two version counters, two prefix options, and a cross-package foreign key.

**The library is standalone.** It is published for consumers who do not run this
application, so it depends on no umbrella app, reads no `:supa_cacher_*` application
environment, and its documentation and examples stand on their own. This repository is
one consumer of the package, not its host. The carve-out therefore happens first
(Phase 1), so the remaining work is written inside the library rather than moved into it
at the end.

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
# One host migration, written once
defmodule MyApp.Repo.Migrations.AddRestdis do
  use Ecto.Migration

  def up, do: Restdis.Migration.up(version: 1)
  def down, do: Restdis.Migration.down(version: 1)
end
```

---

## Phase 1: Standalone Project Carve-Out

Delivers the library as its own Mix project that builds and tests with the umbrella
absent. Everything after this phase is written inside the library, under its final module
names, rather than moved at the end.

1. Create a top-level `restdis/` Mix project with its own `mix.exs`, lockfile,
   `config/`, formatter, and credo configuration, depending on nothing from `apps/`.
2. Move the cache engine into it under its final module namespace. The cache has no code
   references to the other umbrella apps, so it moves whole.
3. Give the library its own `test_helper.exs` and test repo, independent of the umbrella's
   `config/config.exs`.
4. Add the library to the umbrella as a `path:` dependency and reduce
   `apps/supa_cacher_cache` to nothing, deleting it.
5. Add a CI job running the library's `mix check` and `mix test` from its own directory.
6. Add a compile-time guard rejecting any reference from library code to an umbrella
   module.

**Completion criteria:**

- `mix test` inside `restdis/` passes with `apps/` deleted from the checkout.
- The umbrella's suite passes with the cache consumed as a `path:` dependency.
- The library's dependency list contains no umbrella application.

The WAL follower stays in `apps/supa_cacher_buster` until Phase 4, because it cannot move
while it still calls `SupaCacherRepo` and `SupaCacherCache` directly.

## Phase 2: Versioned Migrations

Delivers the Oban-style migration surface. No runtime code changes; the umbrella keeps
running against its existing tables.

1. Add `Restdis.Migration` with `up/1`, `down/1` and `migrated_version/1`, accepting
   `:version`, `:prefix` and `:create_schema`.
2. Add `Restdis.Migrations.Postgres` as the stepwise runner that reads the recorded
   version and applies `V01..VN` in order, reversing for `down`.
3. Add `Restdis.Migrations.Postgres.V01` creating `tenants`, `tenant_table_config` and
   `wal_checkpoint`, collapsing the four existing table migrations minus `api_keys`.
4. Record the applied version in a table comment on `tenants`, read back by
   `migrated_version/1`.
5. Add `Restdis.Migration.create_publication/1` as a separate privileged helper,
   replacing `20260519000003_create_publication.exs`.
6. Replace the four umbrella migrations with a single migration calling
   `Restdis.Migration.up/1`, leaving `api_keys` as an application migration.

**Completion criteria:**

- `up` then `down` then `up` at every released version leaves the schema identical, under
  both the default and a custom prefix.
- `up/1` called twice is a no-op the second time.
- `mix ecto.reset` on the umbrella produces a schema the existing test suite passes
  against.

The project is greenfield with no deployed database, so `V01` assumes a clean database.
It replaces the four umbrella migrations outright rather than adopting a database that
already ran them, and released `V0N` modules are only immutable from `0.1.0` onward.

## Phase 3: Migration Generator

Delivers the one-command install path for a host application.

1. Add `mix restdis.gen.migration` emitting a timestamped host migration that calls
   `Restdis.Migration.up/1` at the current version.
2. Support `--prefix` and `--repo` flags on the generator.

**Completion criteria:**

- The generated file compiles and runs against a fresh database with no hand editing.

## Phase 4: Dependency Inversion and WAL Carve-Out

Delivers per-instance database configuration and a WAL follower that runs without the
cache, then moves it into the library. Repo injection and the handler behaviour are one
phase because both rewrite `SupaCacherBuster.Worker` and `TenantTableConfig`.

1. Resolve start options into an instance config store at boot, keyed by instance name.
2. Thread `repo:` and `prefix:` through `SupaCacherBuster.Infra.LsnStore`, replacing the
   hardcoded `SupaCacherRepo` at three call sites.
3. Thread `repo:` and `prefix:` through `SupaCacherBuster.TenantTableConfig.Cache`.
4. Move the `tenants` and `tenant_table_config` Ecto schemas into the library, prefix-free,
   with `prefix:` passed per query.
5. Read `default_ttl_s` and `persist_cap` from `tenants` through the injected repo, behind
   the tenant aggregate's config snapshot.
6. Delete the `tenant_config_lookup` MFA and its configuration, leaving the `tenants` table
   as the only source of tenant configuration.
7. Define a `handler` behaviour receiving decoded WAL events.
8. Replace the direct `SupaCacherCache.invalidate_by_row/3` and `flush_table/2` calls in
   `SupaCacherBuster.Worker` with a dispatch to the configured handler.
9. Move the `public.tenants` and `public.tenant_table_config` special-casing out of the
   worker into an application-level handler.
10. Ship the cache-invalidating handler as a library module the host can opt into.
11. Move the WAL follower into the library under its final module namespace and delete
    `apps/supa_cacher_buster`.

**Completion criteria:**

- Two instances with different repos and prefixes run concurrently in one VM without
  interfering.
- `persist_cap` comes from the `tenants` row, with no hardcoded 50,000 fallback.
- The WAL follower starts and delivers events with the cache tree not started.
- The library's dependency list still contains no umbrella application.

**Risks:**

- The cache read path currently reaches tenant config synchronously. Adding a repo read
  behind it risks a latency regression on cold tenants; the config snapshot must be
  populated once at aggregate start, not per request.
- This is the largest phase. Steps 1-6 and 7-10 are separately committable and should be
  landed as two runs of the red-green-refactor cycle, with step 11 last.

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

## Phase 6: Publish

Delivers `restdis` on Hex as a package with no knowledge of this application.

1. Add `package/0`, `docs/0`, licence, and `CHANGELOG.md`.
2. Write a README covering the two child specs, the migration install path, the handler
   behaviour, and a worked example that does not reference SupaCacher the product.
3. Verify `mix hex.build` ships only the library's own files.
4. Publish `0.1.0` and switch the umbrella from the `path:` dependency to the released
   version.

**Completion criteria:**

- A scratch Mix project consuming the published package can start both trees, run the
  generated migration, and cache a key, with this repository absent.
- Generated docs cover the two child specs, the migration module, and the handler
  behaviour.

---

## Resolved Questions

**The library lives in this repository,** as a top-level `restdis/` directory consumed by
the umbrella as a `path:` dependency until Phase 6. One repository keeps every phase a
single change; the boundary is enforced by the dependency list and the Phase 1 compile-time
guard rather than by separate checkouts.

**Tenant config comes only from the repo.** There is no read-through behaviour, MFA hook,
or escape hatch for tenant configuration: a consumer of the library runs the migration and
populates `tenants`. This is what makes Ecto a genuine requirement rather than one adapter
among several.

**The package is named `restdis`,** matching the repository, with `Restdis` as the public
module namespace and `restdis` as the default schema prefix. The application keeps its
`SupaCacher*` namespace; it is a consumer of the package, not the same thing.

**Backwards compatibility is not a constraint.** The project is greenfield with no
deployed database and no external consumers. Renames, schema changes, and migration
rewrites are free up to the `0.1.0` publish in Phase 6, and no phase needs a compatibility
shim or a deprecation path. Module and table names should be moved to their final form
early rather than carried through the phases and renamed at the end.
