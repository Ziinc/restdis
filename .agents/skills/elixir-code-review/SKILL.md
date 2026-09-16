---
name: elixir-code-review
description: "Review the current diff, or a PR/branch/path target, for correctness bugs, DDD boundary and TDD violations, and Elixir-specific cleanups, at a given effort level (low/medium: fewer, high-confidence findings; high→max: broader coverage). With no level given, reuse the level last used. Pass --comment to post findings as inline PR comments, or --fix to apply them to the working tree."
---

Review Elixir changes in this umbrella app for correctness, DDD boundaries, TDD discipline, and Elixir style. Follow these steps precisely.

## 1. Resolve the target

- PR number or URL: use `gh pr diff` and `gh pr view`.
- Branch or path: diff against it.
- No argument: review `git diff` (staged + unstaged); if empty, review the last commit.

## 2. Skip ineligible PRs

Skip and stop if the PR is closed, a draft, trivially simple, automated, or already has a review comment from you.

## 3. Review dimensions

Run each dimension below only on changed lines, unless a dimension says otherwise. Use `AGENT.md` as ground truth for every DDD and TDD claim; quote it when citing a rule.

1. **Correctness.** Shallow scan for real bugs on changed lines. Skip context beyond the diff. Ignore nitpicks.
2. **DDD boundaries.**
   - Bounded contexts are umbrella apps: `restdis`, `restdis_server`, `restdis_buster`, `restdis_replicator`, `restdis_repo`, `restdis_electric`.
   - Cross-app calls go through the owning app's public API only. Flag any reach into another app's internal modules.
   - `restdis` must never reference umbrella modules. Run `mix check.boundary`; don't just eyeball it.
   - Domain modules (pure functions, structs, typespecs) must not depend on infrastructure modules (ETS, CubDB, Postgres, HTTP, RESP).
   - Ubiquitous language: flag synonyms for PRD terms (`tenant`, `cache_key`, `reverse_index`, `rewarm`, `persist`, `replication mode`, `TTL mode`, `query_cache`, `disk_cache`, `wal_tailer`, `wal_fanout`). Example: "bust" for "invalidate" is wrong.
3. **TDD adherence.**
   - Every new or changed function or GenServer callback needs a preceding or co-located test. Flag production diffs with no matching test diff.
   - Cache invariants (`get`/`put`/`delete`) need a `StreamData` property test (PRD Phase 1).
   - A bugfix with no failing-test-first evidence is a red flag; ask whether red was confirmed before green.
4. **Helper hygiene.**
   - Shared helpers (2+ modules) belong in the app's common module, not duplicated.
   - Test helpers belong in that app's single `test/support/test_utils.ex`, not copy-pasted per file.
   - Single-use helpers should stay `defp`. Flag premature public extraction.
5. **Elixir style.** Check the changed app's own `.credo.exs` first (e.g. `apps/restdis/.credo.exs` overrides root), then:
   - Public functions have `@doc` and `@spec`.
   - Functions take at most 4 arguments.
   - No `String.to_atom`, `List.to_atom`, `:erlang.binary_to_atom`, or `:erlang.list_to_atom` on runtime data.
   - Module layout follows `AGENT.md` order: `@moduledoc`, `@behaviour`, `use`, `import`, `require`, alphabetical `alias`, attributes, struct, types, callbacks, macros, `def`s.
   - Predicate functions end in `?`.

## 4. Score confidence

For each finding, score 0-100 confidence it is real and worth fixing:

- 0: false positive or pre-existing issue.
- 25: plausible, unverified, or an uncalled-out stylistic preference.
- 50: verified but minor or rare in practice.
- 75: verified, will be hit in practice, or directly required by `AGENT.md`.
- 100: certain and frequent.

Drop findings below 80.

False positives — do not report:

- Pre-existing issues.
- Looks like a bug but isn't.
- Nitpicks a senior engineer wouldn't raise.
- Anything a linter, compiler, or `mix check` (`compile --warnings-as-errors`, `format --check-formatted`, `credo --strict`, `ast-grep scan`) would catch on its own. Exception: the ast-grep `@doc`/`@spec` and single-line-comment rules are custom, not stock Credo — still report violations of those.
- General code-quality wishes (test coverage, docs) not required by `AGENT.md`.
- Issues explicitly silenced with a lint-ignore comment.
- Intentional, related changes.
- Real issues on lines the diff didn't touch.

## 5. State findings as assertions

Every finding is one sentence, stated as an assertion, no vague verbs ("improve", "clean up", "handle edge cases"). State the rule broken and the fix, nothing else. Cite `file:line`.

Bad: "Consider improving error handling here."
Good: "`Cache.put/3` swallows `{:error, _}` from `CubDB.put/3` instead of propagating it (file.ex:42)."

## 6. Report

- Default: print numbered findings to the terminal, each with its `file:line` citation. No header ceremony beyond a one-line count.
- `--comment`: post the same findings via `gh pr comment`, one comment, numbered list, each citing `file:line` with a full-SHA GitHub link. End with a 👍/👎 react-to-rate line. No emoji elsewhere.
- `--fix`: after reporting, apply each finding to the working tree. Then run `mix check.compile` and `mix test` for the touched files. Report red/green status.
- No findings above 80: report "No issues found" and stop, don't post a PR comment.
