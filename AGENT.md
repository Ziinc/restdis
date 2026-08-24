
# Workflow

All coding agents working in this repo MUST follow the workflow below. These rules are mandatory, not advisory.

## Source of Truth

`PRD.md` is the authoritative reference for SupaCacher's scope, architecture, naming, phase boundaries, invalidation modes, and limits. When a requirement is ambiguous:

1. Consult `PRD.md` first. Quote the relevant section in the task notes or PR description when a decision rests on it.
2. Never introduce behavior that contradicts the PRD.
3. If the PRD is silent on the question, ask the user before assuming. Do not invent.

## Domain-Driven Design (mandatory)

DDD is required for every change in this repo.

**Bounded contexts = umbrella apps.**
- `supa_cacher_cache` — cache engine, reverse index, per-tenant ETS and CubDB.
- `supa_cacher_server` — Redis RESP protocol, HTTP endpoint, rewarm scheduling.
- `supa_cacher_buster` — WAL ingestion and invalidation/refresh dispatch.
- `supa_cacher_replicator` — always-live KV datasets.

Cross-context calls go through the owning app's public API only. Never reach into another app's internal modules.

**Ubiquitous language.** Use PRD terminology exactly: `tenant`, `cache_key`, `reverse_index`, `rewarm`, `persist`, `replication mode`, `TTL mode`, `query_cache`, `disk_cache`, `wal_tailer`, `wal_fanout`. No synonyms — don't say `bust` when PRD says `invalidate`.

**Layering inside an app.** Domain (pure functions, structs, typespecs) → Application (GenServers, supervisors, orchestration) → Infrastructure (ETS, CubDB, Postgres, HTTP, RESP). Domain modules must not depend on infrastructure modules.

**Aggregates.** A tenant is the aggregate root for cache state: one ETS table, one CubDB instance, one reverse index, one config snapshot. All writes for a tenant route through that aggregate.

## TDD (strict red-green-refactor, mandatory)

For every new function, GenServer callback, or behavior:

1. **Red:** write the failing test first. Run it. Confirm it fails for the *expected reason* (assertion failure, not a compile error).
2. **Green:** write the minimum code to make the test pass. No extra branches, no speculative parameters.
3. **Refactor:** clean up with the test still green. Re-run after every refactor step.

Rules:
- **Per unit, not per task.** Cycle through red-green-refactor for each unit, not once per feature.
- **No production code without a failing test first.** If a bug is found, reproduce it with a failing test before fixing.
- **Commit cadence.** Each red→green→refactor cycle should be small enough to fit one commit. Never skip the red step.
- **Property-based tests** for cache invariants (PRD Phase 1 requires this for get/put/delete). Use `StreamData`.

## Task discipline

Every task in a plan or PR must be:

- **One sentence, one outcome.**
- **Stated as an assertion.** Example: "After `Cache.put/3`, `Cache.get/2` returns `{:ok, value}` and the reverse index contains `{table, pk}`."
- **Concise and precise.** No vague verbs like "improve", "clean up", "handle edge cases". Replace them with the assertion that proves the change.

If a task cannot be expressed as a clear assertion, it is not ready — split it until each piece can.

## Utility and helper hygiene

- **Shared production helpers** (used by 2+ modules) go into a common utility module within their owning app (e.g., `SupaCacherCache.Common`). Promote to a cross-app utility only when at least two umbrella apps need it. Never duplicate.
- **Locally-used helpers** (single module) stay private (`defp`). Do not pre-emptively extract.
- **Test helpers** live in a single `test/support/test_utils.ex` per app, compiled via `elixirc_paths` in that app's `mix.exs`. Examples: tenant setup, ETS table fixtures, CubDB temp directories, WAL event factories. No copy-pasted setup blocks across test files.
- **Before adding a helper**, grep the existing common module and `test_utils.ex` — reuse first.

## Shell command hygiene

- Do not append `echo "EXIT:$?"` to commands. Same for variants like `; echo $?`, `&& echo OK || echo FAIL`. The shell already surfaces exit codes; the extra echo pollutes output and masks the real status from tooling.
- To branch on exit status, use the exit code directly (`if mix test; then …`), not a printed string.

## Definition of Done

A change is done only when:

- All new functions have typespecs.
- All new behavior has a failing-first test that now passes.
- `mix test` is green and `mix lint` (`mix format --check-formatted` plus `mix credo --strict`) is clean.
- No cross-context internal reach-ins were introduced.
- The PR or task description cites the PRD section the change implements (e.g., "Phase 2, step 4: `PGRST.QUERY`").

---

## Code Style

**Module organization** (in order, with blank lines between groups):
1. `@moduledoc`
2. `@behaviour`
3. `use`
4. `import`
5. `require`
6. `alias` (individual lines, alphabetically sorted - never `alias Foo.{Bar, Baz}`)
7. `@module_attribute`
8. `defstruct`
9. `@type`
10. `@callback`, `@macrocallback`, `@optional_callbacks`
11. `defmacro`, `defguard`
12. `def`

**General style**:
- Create typespecs for new functions; prefer typespecs over verbose docs
- Avoid inline comments; rely on clear logic and typespecs
- No `@moduledoc` (or `@moduledoc false`) in test files
- Predicate functions end with `?` (e.g., `valid?/1`); reserve `is_` prefix for guards

## Elixir Pitfalls

These are common mistakes - avoid them:

**List access**: Lists don't support bracket access. Use `Enum.at/2`:
```elixir
# Wrong: mylist[0]
# Right: Enum.at(mylist, 0)
```

**Block rebinding**: Must capture the result of `if`/`case`/`cond`:
```elixir
# Wrong - assignment inside block is lost:
if connected?(socket), do: socket = assign(socket, :val, val)

# Right - capture the block result:
socket = if connected?(socket), do: assign(socket, :val, val), else: socket
```

**Struct access**: Structs don't implement Access. Use dot notation or specific APIs:
```elixir
# Wrong: changeset[:field]
# Right: changeset.field or Ecto.Changeset.get_field(changeset, :field)
```

**Additional guidance**:
- Never nest multiple modules in the same file (causes cyclic dependencies)
- Avoid `String.to_atom/1` on user input (memory leak risk)
- OTP primitives need names: `{DynamicSupervisor, name: Logflare.MySup}`
- Use standard library for date/time (`DateTime`, `Date`, `Time`, `Calendar`)
