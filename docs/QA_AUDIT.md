# QA audit: production readiness (2026-09-28)

Scope: the whole umbrella at `d93be43`, checked against `prds/PRD.md`, `prds/ELECTRIC_PRD.md`,
`prds/LIB_PRD.md` and `README.md`.

Method:

- Built the **prod release** (`MIX_ENV=prod mix release restdis`) and ran it against Postgres 16
  (`wal_level=logical`) and a real PostgREST 12.2.3.
- Seeded three tenants (`open`, `gatekeeper`, and one pointing at a request-logging origin).
- Drove the release with `redis-cli`, raw RESP sockets, `curl`, `redis-benchmark`, **ioredis 5**,
  **node-redis 4**, **redis-py 8** and **@electric-sql/client 1**.
- Ran a static review of every bounded context in parallel.

Each finding is tagged:

- **Verified**: reproduced against the running release. The evidence is quoted.
- **Static**: found by code reading and not reproduced here, mostly multi-node paths, since only a
  single node was run.

Severity:

- **P0**: ship blocker. Data exposure, wrong data served, or an outage.
- **P1**: must fix before GA. A PRD or README promise is broken.
- **P2**: hardening.

## Summary

The single-node happy path works: `PGRST.QUERY`, and `UPDATE`/`DELETE`-driven invalidation of
single-row and list keys over RESP and `/pgrst/query`. Electric snapshots and live updates on
unfiltered shapes also work, and the per-app test suites are green. However, **the server is not
production quality yet**. The review found:

- one unauthenticated remote memory DoS
- one SSRF/path traversal that sends the tenant's PostgREST key to arbitrary upstream paths
- several ways to serve stale or wrong data indefinitely
- a WAL pipeline that one bulk write to an unrelated table can stall for minutes
- one malicious Electric `where` clause that stops live updates for a table
- a release that never exits on `SIGTERM`
- mainstream Redis clients (ioredis and redis-py with default options) that cannot connect

## P0: ship blockers

### P0-1: Unauthenticated RESP memory and CPU DoS (Verified)

`apps/restdis_server/lib/restdis_server/resp/parser.ex`, `resp/handler.ex`

- There is no limit on bulk length, array count, or inline line length, and no limit before AUTH.
  Each packet re-parses and re-copies the entire buffer (`state.buffer <> data`), so the work is
  quadratic.
- Evidence: one unauthenticated connection declaring `$1000000000` and streaming data took the BEAM
  from **212 MB to 1.3 GB RSS after 75 MB sent**. Throughput collapsed: 25 MB took 17 s, 50 MB took
  85 s, and 75 MB took 204 s. Sixteen thousand such connections are allowed.
- `*-1\r\n` (a RESP null array) or any negative count hangs the connection forever and swallows every
  later command.
- `*1\r\n$-1\r\n` (nil command name) and `$-5` (negative bulk length) crash the connection process
  with no reply (`FunctionClauseError` in `String.upcase/2` and `parse_bulk_bytes/2`).
- Fix:
  - Reject counts below -1.
  - Cap bulk length (512 MB after auth, a few KB before), inline length (64 KB) and array length.
  - Keep a parse offset between packets instead of re-parsing from byte 0.
  - Answer nil arguments with `ERR`.

### P0-2: Path traversal / SSRF with the tenant's PostgREST credential (Verified)

`restdis/cache/key.ex` (`decode/1` URI-decodes `ident`), `postgrest/fetcher.ex` (`path_for/2` keeps
`/` and `..`), `rewarm/scheduler.ex`

- Evidence: tenant base URL `http://127.0.0.1:3001/rest/v1` with `pgrst_api_key=SERVICE_ROLE_SECRET`.
  - `PGRST.POLICY pgrst:t:..%2F..%2Fauth%2Fv1%2Fadmin%2Fusers:0 REWARM 1` made Restdis request
    `GET /rest/v1/../../auth/v1/admin/users apikey=SERVICE_ROLE_SECRET`.
  - `PGRST.QUERY '../../auth/...'` produced `/rest/v1/..?x=1`.
- Any tenant API key holder can therefore make Restdis call any path on the origin host with the
  tenant's server-side key. On Supabase that is `/auth/v1/admin/*` and `/storage/v1/*`, and gateways
  normalise `..`.
- Fix: validate `ident` against `^[A-Za-z0-9_$.-]+$` (rejecting `.` and `..`) in both `Key.decode/1`
  and `QueryParser`, and percent-encode `/` in `path_for/2`. Never start rewarm on a key that was
  not produced by `PGRST.QUERY`.

### P0-3: `HotCache` serves expired and invalidated data for up to 5 minutes (Verified)

`restdis/cache/hot_cache.ex`, `restdis/cache/router.ex:35-49`, `restdis/cache.ex:157-174`

This comes from the cluster-wide hot layer added in #76. The PRD does not describe it, and it
contradicts PRD "TTL mode".

- Every `Router.get` stores the value locally with a **fixed 5-minute TTL**, whatever the entry's
  own TTL.
- Evidence: `PGRST.QUERY … TTL 2`, `GET`, wait 4 s, then `GET` still returns the row while `TTL`
  reports 0.
- The same applies to `SET k v PX 500`. SETNX-style locks can't be re-acquired and INCR rate-limit
  windows never reset.
- `invalidate_lists/3` (the WAL INSERT path) never calls `HotCache.delete`.
  - Evidence: a list cached via `PGRST.QUERY 'widgets?id=gt.48'` and read via `GET`, then
    `INSERT id=51`, and `GET` still returned `[49,50]`. The same list over `/pgrst/query`, which
    does not use `HotCache`, was correctly re-fetched.
- `flush_tenant`, TTL sweep, ETS/CubDB eviction and `PGRST.POLICY TTL` don't clear it either.
- It has no size cap and is not counted in `ets_cap_bytes`.
- It is not instance-scoped, which conflicts with #66: a host that mounts only a non-default instance
  raises `ArgumentError`, and two instances share entries.
- Gossip put/delete are unordered across nodes, so a delete can be overtaken by an older put.
- Fix: until it can be made TTL- and invalidation-correct, remove it or disable it by default. If it
  stays: store `min(remaining_ttl, 5 min)`, clear it on every invalidation path through one helper,
  add a byte cap, scope it per instance, and version entries.

### P0-4: WAL invalidation throughput is ~940 events/s cluster-wide, backlog unbounded (Verified)

`restdis_buster/worker/supervisor.ex` (FanoutSubscriber), `tenant_table_config/cache.ex`

- For every decoded change, including tables no tenant caches, the single `FanoutSubscriber` makes a
  synchronous `tenant_table_config` lookup. Misses are not cached.
- Evidence: `INSERT … generate_series(1,200000)` into an unconfigured table, then:
  - The `FanoutSubscriber` mailbox reached **149,508 messages**, draining at **937 events/s**.
  - A cached `widgets?id=eq.15` entry was **not invalidated for ~4 minutes** after its row was
    updated.
  - The slot held **123 MB** of WAL with `confirmed_flush_lsn` frozen for the whole period.
- Any sustained write rate above ~1k rows/s anywhere in the database (auth, storage, audit tables)
  means invalidation never catches up and memory grows until OOM.
- Fix:
  - Filter on the relation id against an in-memory set of configured tables, and cache negative
    lookups.
  - Ack skipped events.
  - Partition work per tenant/table instead of through one process.

### P0-5: One Electric `where` clause stops live updates for a table (Verified)

`restdis_electric/eval.ex:676`, `restdis_electric.ex` (shape registration), `restdis_electric/wal.ex:81-105`

- Evidence:
  1. `GET /v1/shape?table=widgets&offset=-1&where=(id << 100000000000) > 0` returned **500**, but
     the shape stayed registered.
  2. From then on, every WAL event on `widgets` for that tenant crashed its worker Task
     (`SystemLimitError :erlang.bsl(920, 100000000000)`, 34 crashes in the log).
  3. **All other shapes on the table stopped receiving inserts and updates.** Snapshots still worked;
     live polls returned only `up-to-date`.
  4. The crashed events are never acked, but `LsnStore` still confirms later LSNs.
- The same applies to `badarith` (for example `price * 1e300 * 1e300`). The static review also found
  unbounded recursion in the Rust NIF (`encode_expr`/`Drop`). A deeply nested `1+1+…` of about 8 KiB
  would overflow the dirty-scheduler stack and segfault the VM (not reproduced).
- Fix:
  - Evaluate every `where` against a sample row (and bounds-check shifts and arithmetic) before
    registering.
  - Rescue per-shape in `WAL.ingest` so one shape can never affect another.
  - Cap NIF parse depth.

### P0-6: The release never stops on `SIGTERM` (Verified)

`restdis/cache/supervisor.ex:41-47`

- `start_link/1` returns `{:ok, existing_pid}` when the instance is already running.
- `restdis_replicator`, `restdis_server` and `restdis_buster` all mount `{Restdis.Cache, …}` with
  the default name. Only the first becomes the supervisor's parent.
- On shutdown, `RestdisBuster.Supervisor` sends `shutdown` to a supervisor it does not own. That
  supervisor ignores `EXIT` from non-parents, and the child's shutdown is `:infinity`.
- Evidence: after `SIGTERM received - shutting down`, the VM was still running **160 s later**, with
  `RestdisBuster.Supervisor` stuck in `supervisor:shutdown/1`. `bin/restdis stop` hangs the same way.
- In Kubernetes or Docker every deploy therefore ends in `SIGKILL`: CubDB isn't closed cleanly and
  the WAL slot isn't released.
- A second effect: the mount options of the second and third apps (`data_dir`, `origin`) are
  silently ignored.
- Fix: mount `Restdis.Cache` once, in the app that owns it, and have the others depend on it. Or
  return `:ignore` (not `{:ok, pid}`) when it is already started.

### P0-7: Entries surviving a restart can never be invalidated (Verified)

`restdis/cache/disk_cache.ex` (`rebuild_index`), `restdis/cache/reverse_index.ex`

- Every put is written to CubDB, but the reverse index lives only in ETS and is not rebuilt at boot.
- Evidence:
  1. Cache `widgets?id=eq.11` with `TTL 3000`, then restart the release.
  2. `UPDATE widgets SET name='POST_RESTART' WHERE id=11`.
  3. RESP `GET` and `/pgrst/query` both still return `w11`, while PostgREST returns `POST_RESTART`.
- The entry stays stale for the full TTL, and `persist` entries stay stale for up to `max_ttl_s`
  (default 30 days).
- A crash of the `ReverseIndex` process (supervised `one_for_one`) causes the same thing without a
  restart.
- Fix: store the pks and list flag in the disk entry and rebuild the index in `init`, or drop
  non-persist entries at boot. Supervise the aggregate `one_for_all`.

### P0-8: The cache is not identity-aware, so Postgres RLS is bypassed (Static, design gap)

`postgrest/fetcher/req.ex`, `restdis/cache/key.ex`, `restdis_repo` `api_keys`

- Every fetch uses `apikey: tenant.pgrst_api_key`. The caller's JWT is never forwarded.
- API keys have no role or scope.
- The cache key has no role/claims component.
- Consequences:
  - Any key holder for a tenant reads whatever the tenant's upstream key can read (service role
    means RLS is off).
  - A response is shared across all users of the tenant.
  - Against a bare PostgREST every read runs as the anon role.
- That is acceptable only for fully public data. It is not stated in the PRD and conflicts with the
  Supabase integration goals.
- Fix: forward `Authorization` and hash the role and relevant claims into the key, or restrict
  caching to tables/keys explicitly marked public and refuse a service-role `pgrst_api_key`.

### P0-9: Different queries share a cache entry (Verified in part)

`restdis_server/pgrst/query_parser.ex`, `restdis/cache/key.ex:24`, `query_store.ex`

- Path segments after the first are dropped.
  - Evidence: `path=/widgets/../secrets` returned the **full `widgets` table**, because it has the
    same key as `/widgets`.
- `URI.decode_query/1` keeps only the last duplicate parameter.
  - For example, `?id=gt.1&id=lt.9` has the same key as `?id=lt.9`, but PostgREST ANDs both filters.
- `params_hash` is `:erlang.phash2/1`, which is only 27 bits wide. Expect the first collision at
  roughly 11k distinct queries per table (for example `?id=eq.<n>` lookups).
- `QueryStore` keeps one query string per key, so after a collision the rewarm fetches one query and
  serves it for the other.
- Fix: build the key from the canonical path plus the ordered list of params (and relevant headers)
  and hash it with SHA-256. Store the canonical query in the entry itself.

## P1: PRD / README promises that are broken

### P1-1: WAL invalidation semantics are incomplete (Verified unless noted)

Each item below was tested against PRD "WAL-driven invalidation":

| Scenario | Result |
| --- | --- |
| `UPDATE` moves a row into a cached filtered list (`?status=eq.open`, row 1 closed to open) | Stale; lists are only purged on INSERT |
| Embedded resource changes (`widgets?select=id,orders(qty)`, then `UPDATE orders`) | Stale |
| `TRUNCATE orders` | Stale |
| `DROP TABLE` | Static: `START_REPLICATION` lacks `messages 'true'` (`tailer.ex:124`), so the event-trigger message is never delivered. The integration test is excluded by default. |
| Tenant without a `tenant_table_config` row (tenant `tb` caching `widgets`) | Never invalidated |
| Two tenants configuring the same table | Static: `limit 1` with no tenant filter, so one tenant is picked arbitrarily |
| pk column other than `id`, text pk `"007"`, composite pk | Static: `index_value` hardcodes `"id"` and callers never pass `pk_column`; `coerce_pk` turns `"007"` into `7` |
| Views / RPCs | Never invalidated (TTL only) |
| Origin fetch in flight while invalidation lands | Static: the old value is written after the delete, with no epoch or tombstone |

### P1-2: "Existing Redis clients work unchanged" is false (Verified)

| Client / usage | Result |
| --- | --- |
| **ioredis 5**, default options | Fails: `ERR unknown command 'INFO'` (ready check), connection closed. Works only with `enableReadyCheck:false`. |
| **redis-py 8**, default options | Fails: `AuthenticationError`, because it sends `HELLO 3 AUTH …`. Works only with `protocol=2`. |
| `redis://default:KEY@host` URLs (node-redis, ioredis `username`, redis-py `from_url`) | Fails: `AUTH user pass` returns a wrong-args error |
| node-redis `quit()` | `ERR unknown command 'QUIT'` |
| `SELECT 0`, `CLIENT SETNAME`, `HELLO`, `COMMAND`, `ECHO` | Unknown command |
| Colon-namespaced keys (`SET user:1 v`, the Redis convention) | Rejected. **The repo's own `demos/redis/demo.sh` step 3 (`SET demo:counter 1`) fails**, and so does `redis-benchmark -t set`. |
| Idle pooled connections | Static: ThousandIsland default `read_timeout` is 60 s; real Redis defaults to no timeout |

Fix: support two-argument `AUTH`, `HELLO 2`/`HELLO 3` (reply `-NOPROTO` for 3 if RESP3 is out of
scope), `INFO` (minimal), `SELECT 0`, `QUIT`, `ECHO`, `CLIENT SETNAME/SETINFO`, and `COMMAND`
(empty). Set `read_timeout: :infinity`. Pick a key namespace that doesn't collide with `user:1`
(for example, reserve only `pgrst:` and `repl:` prefixes).

### P1-3: The README's HTTP proxy doesn't exist (Verified)

- README Quickstart: `curl "http://localhost:4040/products?select=id,name" -H "SC-Cache: true"`
  returns **404**.
- No `SC-Cache`, `SC-Cache-TTL` or `SC-Cache-Rewarm` **request** header is read anywhere; they are
  only set on responses (PRD "Redis protocol": "Both are also reachable over the HTTP endpoint via
  `SC-Cache`…").
- `/pgrst/query` always uses `default_ttl_s`.

### P1-4: Tenant limits are not enforced (Verified)

- `persist_cap`:
  - Tenant `ta` has `persist_cap=5`, and **7 of 7** `PGRST.POLICY … PERSIST` calls returned `OK`.
    `Restdis.Cache.set_persist/4` reads the instance default (50,000) and ignores the
    `persist_cap:` option the command passes (`cache.ex:236`).
  - The error text is `ERR persist cap reached`, while the PRD says `…for tenant`.
  - The HTTP `/pgrst/policy` `persist` never calls `set_persist`.
  - Static: the `PERSIST` command never passes `persist: true`, and any later put resets the flag.
- `max_ttl_s`: with `max_ttl_s=300`, `PGRST.QUERY … TTL 99999`, `PGRST.POLICY … TTL 100000`,
  `SET … EX 100000` and `EXPIRE … 100000000` were all accepted, as was `/pgrst/policy`
  `ttl_s: 999999999`.
- Argument validation: `PGRST.QUERY … TTL -5`, `TTL abc`, `REWARM 0` and `BOGUS 1` are all silently
  accepted. `REWARM 0` re-fetches on every 500 ms tick.

### P1-5: Redis command semantics (Verified)

- `RENAME k k` **deletes `k`** (Redis keeps it and replies `OK`).
- `DEL nope1 nope1` returns `2`, and `DEL` of three missing keys returns `3`. Lock-release code
  depends on this count.
- `INCR` at `9223372036854775807` returns `9223372036854775808`; Redis returns an overflow error.
- `INCR` is not atomic: 20 clients × 50 `INCR` produced **967**, not 1000. SETNX/GETSET/APPEND/RENAME
  use the same read-then-write pattern (static).
- `PGRST.POLICY <missing key> TTL 60` writes `nil`, so `GET` returns `null` and
  `PGRST.QUERY`/`/pgrst/query` treat it as a **hit** from then on. A test enshrines this
  (`pgrst_policy_test.exs`).
- Static: SET options are case-sensitive, `SET … GET`/`EXAT`/`PXAT` are missing, and `PX -1` gives a
  syntax error instead of `invalid expire time`.

### P1-6: Numeric precision loss (Verified)

Responses are decoded with Jason and re-encoded:

- `numeric` `12345678901234567890.123456789` is served as `1.2345678901234567e19`.
- Key order changes, and the PostgREST response bytes, headers and status are not preserved.

Fix: store the upstream body bytes as received (plus content type); decode only where the reverse
index needs pks. Otherwise decode with `floats: :decimals`.

### P1-7: API key revocation (Verified / Static)

- A RESP connection authenticated with a key keeps working after the key is revoked (verified: `SET`
  on the same connection returned `+OK`).
- New `AUTH` and HTTP requests keep succeeding until the control-plane cache TTL expires
  (`CONTROL_PLANE_CACHE_TTL_MS`, 60 s).
- `api_keys` changes are not watched in the WAL, whereas `tenants` changes are.

### P1-8: Electric protocol deviations (Verified unless noted)

- A `where` on a column not in `columns` returns an **empty snapshot**. Postgres has 3 matching rows
  for `columns=id,name&where=status='open' and id<6`; Restdis returns only `up-to-date`, because the
  snapshot fetches only the projected columns.
- The 409 response has no `electric-handle` header, and its body is
  `{"error":…,"handle":…}` instead of `[{"headers":{"control":"must-refetch"}}]`.
- `electric-schema` reports `"id":{"type":"integer","not_null":false}` for a `PRIMARY KEY` column.
  Electric sends `int4`, `not_null:true` and `dims`.
- `queryable_columns` (ELECTRIC_PRD "Open mode") **is not implemented anywhere**. Open mode exposes
  every table and column the upstream key can read. `DELETE /v1/shape` skips the `secret` check, and
  the secret is compared with `==`.
- Static:
  - Every `offset=-1` request without a handle creates a new shape and a new snapshot (no dedup), and
    resume registers arbitrary handles, so shapes are unbounded.
  - Shape logs count against the tenant `persist_cap` and share the PGRST cache.
  - Log appends run in concurrent Tasks with `unique_integer` op offsets, so ordering is not
    guaranteed.
  - NULL and unchanged-TOAST columns are dropped from WAL rows (`pgoutput.ex:184-187`), so
    `SET col = NULL` is never delivered and filters see NULL.
  - Arrays and timestamps are compared as text, and differ between the snapshot and the WAL.
  - `offset=now` echoes `now`.
  - TRUNCATE, DROP and restart don't produce a 409.

### P1-9: WAL durability (Static, partly Verified)

- `LsnStore` confirms the node-local **max** applied LSN, not a contiguous watermark. Events are
  applied by concurrent Tasks, and `:syn.publish` fan-out is fire-and-forget. A change can therefore
  be confirmed to Postgres before it has been applied, or while the owning node is down. That
  violates the ELECTRIC_PRD durability rule and silently loses invalidations.
- The slot only advances when configured-table events are applied. Verified: 123 MB retained during
  the P0-4 backlog. With `max_slot_wal_keep_size` set, the slot is eventually invalidated; without it,
  the Postgres disk fills.
- Errors from `CREATE_REPLICATION_SLOT` (missing privilege, `wal_level`, slot limits) are swallowed
  by a catch-all `handle_result`, so the tailer idles while reporting healthy.
- Every node writes `wal_checkpoint`, and the last writer wins.

### P1-10: Multi-node correctness (Static, a 2-node cluster was not run)

- `DEL`, `GETDEL`, `EXPIRE`, `MGET`, `EXISTS`, `TTL`, `DBSIZE`, `RENAME`, rewarm writes and
  `PGRST.POLICY` call `Restdis.Cache` directly instead of `Router`. On a non-owner node they read or
  write the wrong node, and they start a tenant aggregate there.
- `QueryStore` and `PolicyStore` are node-local ETS. An owner-side rewarm or miss for a key parsed on
  another node fetches the **unfiltered** table (`QueryStore.get/2` returns `""`) and stores it under
  the filtered key.
- `Cluster.Migration` ships entries without TTL (so they become immortal), doesn't retry after an
  early `nodeup`, and lets an older value overwrite a newer one.
- `/v1/shape` is not routed to an owner, so behind a load balancer clients loop on 409s.

### P1-11: Rewarm (Static)

`rewarm/scheduler.ex:194`

- `next_due_ms` is pushed back on every touch, so a key read more often than its interval is
  **never** rewarmed. This contradicts the README ("rewarmed … every 30 seconds while the entry stays
  hot").
- Failing keys are re-fetched forever.
- Rewarm resets the TTL to `default_ttl_s`.

## P2: Hardening

- **Unauthenticated `/metrics`** (Verified). It exposes tenant ids (`tenant_id="ta"`), table names
  and node names. The `rewarm.error` metric tags on an arbitrary `reason` term, which gives unbounded
  label cardinality.
- **`/pgrst/policy` returns 500** on a valid JSON body that isn't an object (`[1,2]`, `"str"`)
  (Verified). `read_body` `{:more, …}` isn't handled either.
- **Secrets are stored in plaintext** (Verified):
  - API keys are the `api_keys` primary key.
  - `pgrst_api_key`, `direct_pg_url` and `shape_secret` are stored as-is.
  - The on-disk control-plane CubDB (`cache/control_plane/read_through/tenant_config/1.cub`) holds
    `SERVICE_ROLE_SECRET` and every API key.
- **AUTH brute force goes straight to Postgres** (Static). There is no negative cache and no rate
  limit, so unauthenticated clients can drain the shared repo pool.
- **Error bodies leak internals.** `inspect(reason)` appears in 400/502 bodies and RESP errors.
- **Stores grow without bound** (Static): `QueryStore` (every distinct query string, even failed
  ones), `PolicyStore`, reverse-index `fwd`/`rev`/`list_keys` (never cleaned on TTL expiry or
  eviction), `HotCache`, and the QueryCache LRU index, which orphans entries under concurrent reads.
- **No miss coalescing.** N concurrent misses make N PostgREST requests. Req runs with default
  timeouts and redirects, and the `apikey` header is forwarded on cross-host redirects.
- **The default OTLP endpoint in prod is `localhost:4318`**, so the logs show
  `client error exporting … econnrefused` every 10–15 s when no collector runs (Verified). Default
  the exporter to off unless `OTEL_EXPORTER_OTLP_ENDPOINT` is set.
- **Dependencies**: `mix hex.audit` / `deps.get` report six advisories on **mint 1.9.3** (two HIGH:
  CVE-2026-91043, CVE-2026-82728) and flag `ts_chatterbox 0.16.0` and `websock 0.5.3`. Mint is the
  PostgREST client transport.
- **Gates that give false assurance**:
  - `mix check.sobelow` prints "does not appear to be a Phoenix application" and scans nothing.
  - Dialyzer wasn't run here.
- **The test workflow is broken as documented.** `mix test` from the root (the command AGENT.md's
  Definition of Done requires) fails about 250 tests. The umbrella runs apps in one VM, and
  `hot_cache_test.exs` restores `:hot_cache_transport` to `nil`, so later apps hit
  `nil.broadcast/1`; `unknown registry` errors follow. `restdis_replicator` also fails standalone
  because `plug` is not a declared test dependency. CI stays green only because it runs each app
  separately.

  | Run | Result |
  | --- | --- |
  | `apps/restdis` | 170/170 pass |
  | `restdis_repo` | 23 pass |
  | `restdis_electric` | 303 pass |
  | `restdis_server` | 355 pass |
  | `restdis_buster` | 115 pass |
  | `restdis_replicator` standalone | 39/47 pass |

- **The test suite leaves an inactive `restdis_test_slot`** on the shared Postgres cluster, which
  retains WAL.
- **Docs drift**:
  - DEVELOPMENT.md says the runner is "slim Debian", but the Dockerfile uses Alpine.
  - The Dockerfile pins `ERLANG_VERSION=28.1.1`, while `.mise.toml`/CI use 28.5 (DEVELOPMENT.md
    says they match).
  - README lists 8 RESP commands, while the PRD lists 24.
- **Disk errors crash** instead of degrading (Static). `{:ok, _} = CubDB.start_link`,
  `:ok = CubDB.put`, and a missing `{:error, _}` clause in `start_tenant` mean ENOSPC takes the tenant
  down.
- **CubDB disk-LRU `inserted_at` uses `System.monotonic_time`**, which is meaningless across
  restarts (Static).

## Baseline performance (single node, 4 vCPU, 50 clients)

`redis-benchmark GET <cached pgrst key>`: **47k req/s, p50 0.88 ms**. This is served mostly from
`HotCache`, so it is optimistic if P0-3 is fixed by removing that layer.

## Suggested order of work

1. P0-1, P0-2, P0-5: remote, low-effort attacks. Add parser limits, validate `ident`, and pre-check
   and isolate shape evaluation.
2. P0-6: mount `Restdis.Cache` once. This is a small change that unblocks safe deploys.
3. P0-3, P0-7, P1-1: stale-data correctness. Remove or fix `HotCache`, rebuild the reverse index,
   invalidate lists on UPDATE/TRUNCATE, and enable `messages 'true'`.
4. P0-4, P1-9: WAL pipeline. Add a configured-table filter, a negative cache, contiguous LSN acks,
   and per-tenant partitioning.
5. P0-9, P1-6: cache key canonicalisation and storing raw bodies.
6. P0-8: decide the identity model (JWT forwarding and key-by-role, or public-only caching) and write
   it into the PRD.
7. P1-2, P1-3, P1-4, P1-5: client compatibility, HTTP header API, limits, and command semantics.
8. Add regression coverage for each item above. None of the P0 scenarios has a test today. Also add
   a 2-node `:peer` suite so P1-10 can be verified, and fix `mix test` at the umbrella root.

## Appendix: reproduction

Set up the stack:

- Postgres 16 with `-c wal_level=logical`, database `restdis_qa`, tables `widgets` (`REPLICA
  IDENTITY FULL`), `orders` and `secrets`.
- PostgREST 12.2.3 on :3000.
- The release started with:

  ```sh
  DATABASE_URL=ecto://postgres:postgres@localhost/restdis_qa RELEASE_COOKIE=qa \
    CACHE_DATA_DIR=/tmp/cache _build/prod/rel/restdis/bin/server
  ```

- Tenants: `ta` (open, `persist_cap=5`, `max_ttl_s=300`, table config for `widgets`/`orders`, key
  `ka`) and `tb` (gatekeeper, no table config, key `kb`).

Reproduction commands:

```sh
# P0-1 (pre-auth; watch RSS of beam.smp)
python3 -c 'import socket;s=socket.create_connection(("127.0.0.1",6380));s.sendall(b"*2\r\n$4\r\nPING\r\n$1000000000\r\n");[s.sendall(b"a"*(1<<20)) for _ in range(75)]'
printf '*-1\r\n*1\r\n$4\r\nPING\r\n' | nc -q2 localhost 6380       # no reply ever

# P0-2 (point a tenant's pgrst_base_url at a request logger)
redis-cli -p 6380 -a KEY PGRST.POLICY 'pgrst:t:..%2F..%2Fauth%2Fv1%2Fadmin%2Fusers:0' REWARM 1

# P0-3
K=$(redis-cli -p 6380 -a ka PGRST.QUERY 'widgets?id=eq.7' TTL 2); redis-cli -p 6380 -a ka GET $K; sleep 4; redis-cli -p 6380 -a ka GET $K

# P0-4
psql -c "insert into noise(v) select repeat('x',500) from generate_series(1,200000)"   # then UPDATE a cached row and GET it

# P0-5
curl -H 'Authorization: Bearer ka' "localhost:4040/v1/shape?table=widgets&offset=-1&where=(id%20%3C%3C%20100000000000)%20%3E%200"
# then any live shape on widgets stops receiving changes

# P0-6
kill -TERM <beam pid>    # still alive minutes later

# P1-2
node -e "new (require('ioredis'))({port:6380,password:'ka'}).get('x').then(console.log,console.error)"
python3 -c "import redis; redis.Redis(port=6380,password='ka').ping()"
```
