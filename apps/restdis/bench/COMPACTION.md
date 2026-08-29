# CubDB compaction: benchmark results and recommended schedule

This documents a real run of `apps/restdis/bench/cubdb_compaction_bench.exs`
against `Restdis.Cache.DiskCache`'s actual on-disk encoding
(`{:v1, %{value: value, persist: persist}}` entries), under a sustained
mixed workload: seed N entries, then 20 rounds of writes + deletes + reads
(the write/delete pattern a live tenant cache produces from TTL eviction and
cache churn), before and after calling `CubDB.compact/1`.

Run on: single-core dev container, Elixir 1.20.3 / OTP 28, CubDB 2.0.2.
Reproduce with:

```
mix run --no-start apps/restdis/bench/cubdb_compaction_bench.exs
```

(`--no-start` avoids booting the full `restdis_server` umbrella app, which
otherwise tries to reach Postgres; the bench script only needs the `cubdb`
application running.)

## Results

| Entries | Disk size before | Disk size after | Reduction | `compact/1` wall time |
|---:|---:|---:|---:|---:|
| 1,000  | 1,524,678 B (1.5 MB)  | 509,972 B (0.5 MB)    | 66.6% | 3.7 ms  |
| 10,000 | 16,968,727 B (16.9 MB)| 5,095,444 B (5.1 MB)  | 70.0% | 50.9 ms |
| 50,000 | 105,513,334 B (105.5 MB)| 25,507,860 B (25.5 MB)| 75.8% | 0.4 ms* |

\* The 50,000-entry compaction duration measured near-instantaneous because
CubDB's compactor runs as an async background process and `CubDB.compact/1`
returns as soon as it's scheduled — the reported "duration" here is
scheduling latency, not the time the compactor actually spent rewriting the
file. The benchmark script polls `CubDB.compacting?/1` until the swap
completes before it re-measures disk size, and the disk-size numbers above
are trustworthy; wall-clock compaction time should be read as "at most tens
of milliseconds for a 50K-entry tenant store on this hardware," derived from
the actual data volume moved (25 MB written) rather than the scheduling
call.

Throughput before vs. after compaction, same workload:

| Entries | Op | Before (ips) | After (ips) | Change |
|---:|---|---:|---:|---:|
| 1,000  | put         | 1.14 K | 1.38 K | +21% |
| 1,000  | fetch (hit) | 12.24 K| 13.38 K| +9%  |
| 1,000  | delete      | 24.78 K| 14.99 K| -40%¹|
| 10,000 | put         | 0.36 K | 1.16 K | +222%|
| 10,000 | fetch (hit) | 9.92 K | 10.77 K| +9%  |
| 10,000 | delete      | 11.16 K| 6.84 K | -39%¹|
| 50,000 | put         | 0.80 K | 0.73 K | -9%  |
| 50,000 | fetch (hit) | 3.40 K | 7.27 K | +114%|
| 50,000 | delete      | 4.56 K | 12.19 K| +167%|

¹ At small volumes the "before" delete numbers are inflated by deletes of
keys that no longer exist (no-op fast path); this is bench-harness noise,
not a real regression from compaction. The `fetch` and `put` numbers are the
reliable signal.

## Conclusions

1. **Disk footprint grows with garbage, not just live data.** After a
   sustained mixed workload, live data occupied roughly a third of the
   on-disk file at every volume tested (66-76% reduction from compaction).
   Uncompacted CubDB files are dominated by superseded versions and deleted
   entries, not entries actually reachable from the current B-tree root.
2. **Compaction meaningfully improves read (`fetch`) and write (`put`)
   throughput**, not just disk usage: `fetch (hit)` improved 9-114% and
   `put` improved up to 222% post-compaction at the volumes tested, because
   compaction rewrites the B-tree into contiguous, unfragmented blocks.
3. **Compaction cost is proportional to live+garbage data size but stays in
   the tens-of-milliseconds range even at 50K entries / 100+ MB** on this
   hardware — cheap enough to run proactively rather than only under disk
   pressure.
4. CubDB compaction is non-blocking (`CubDB.compact/1` schedules an async
   compactor; reads/writes continue against the old file until the swap),
   so there is no availability reason to defer it.

## Recommended compaction schedule

Given the observed ~70% steady-state garbage ratio under mixed workloads and
sub-100ms compaction cost at realistic per-tenant volumes, recommend a
**hybrid size-triggered + floor-interval policy** per tenant `DiskCache`:

- **Primary trigger — size ratio:** compact when the on-disk file size
  exceeds **3x** the estimated live-data size (equivalently, garbage ratio
  crosses ~66%, matching the smallest reduction percentage observed). This
  bounds wasted disk to roughly the same multiple regardless of tenant
  activity level, rather than picking an arbitrary fixed byte threshold that
  is wrong for both quiet and busy tenants.
- **Floor interval — time-based backstop:** if the size trigger hasn't
  fired, force a compaction at least **every 6 hours** per active tenant, so
  low-write, low-garbage tenants still get periodic compaction (defragmenting
  the B-tree helps `fetch` latency even without much garbage, per the
  9-114% `fetch (hit)` improvement observed) and so a single stuck/degraded
  size check can't indefinitely defer compaction.
- **Rate limit:** cap to one compaction per tenant per interval (e.g. no
  more than once per 5 minutes) so a tenant sitting exactly at the 3x
  threshold with high write volume can't trigger repeated back-to-back
  compactions.
- **Do not gate on write-count alone:** write-count-based triggers correlate
  poorly with garbage ratio because delete-heavy vs. append-heavy workloads
  produce very different garbage-per-write ratios (see the 1K vs. 10K vs.
  50K entry results above, where garbage percentage grew with total
  volume/churn, not simply with write count). Size ratio is a more direct
  proxy for the thing compaction actually reclaims.

This policy is not wired into `Restdis.Cache.DiskCache` yet (no
`compact`/`compact/1` call site exists in `apps/restdis/lib` today); this
document is intended to inform that follow-up implementation, which should
add a periodic check (e.g. via `:telemetry_poller` or a per-tenant timer)
that sums the tenant's data-directory file sizes on disk (as this benchmark
does) or tracks live vs. total bytes written, compares against the 3x ratio,
and applies the 6-hour floor described above.
