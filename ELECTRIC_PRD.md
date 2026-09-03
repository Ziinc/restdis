# RFC: An Electric-Compatible Shape API on Restdis

---

## Terms used in this document

Read this section first if you have not worked on Electric or on Restdis. Every later section uses these terms with exactly these meanings.

| Term | Meaning |
| --- | --- |
| **WAL** | Write-Ahead Log. Postgres writes every change to this log before it changes the table itself. Other programs can read the log to learn what changed. |
| **Logical replication slot** | A bookmark that Postgres keeps for one reader of the WAL. Postgres holds the log data until that reader confirms it has processed it. |
| **LSN** | Log Sequence Number. A position in the WAL. LSNs always increase, so they order changes in time. |
| **Shape** | A subset of one Postgres table, defined by a table name, an optional filter, and an optional list of columns. This is Electric's core idea. |
| **Shape log** | The ordered list of insert, update, and delete operations for one shape. A client reads this list to build its own copy of the data. |
| **Offset** | A position in a shape log. A client stores its offset so it can continue from where it stopped. |
| **Handle** | A short identifier for one shape. The client sends the handle back on later requests. |
| **Snapshot** | The first read of a shape. It returns every row that matches the shape at that moment. |
| **Long-poll** | The client sends a request. The server holds the request open until new data arrives or a timer expires. |
| **ETS** | Erlang Term Storage. An in-memory table built into the Erlang virtual machine. Restdis uses it as its fastest cache layer. |
| **CubDB** | An embedded key-value database written in Elixir. Restdis uses it as its on-disk cache layer today. |
| **PostgREST** | A server that turns a Postgres database into an HTTP API. Restdis reads through it. |
| **Tenant** | One customer of the platform. Restdis keeps each tenant's cache and configuration separate. |
| **Bounded context** | One umbrella application in this repository. It owns its own data and exposes a small public API. Other contexts must use that API. |

---

## Problem

ElectricSQL, which we call Electric below, keeps a copy of Postgres data up to date on client devices. It works in three steps.

1. It reads the Postgres WAL through one replication slot.
2. It splits that single stream of changes into shapes. Each shape holds the rows one group of clients needs.
3. It serves each shape as a shape log over an ordinary HTTP API.

Because the API is ordinary HTTP, a browser or a CDN can cache the responses.

Teams do not adopt Electric because the server is hard to build. They adopt it because of the client libraries: `@electric-sql/client`, `@electric-sql/react`, `@tanstack/electric-db-collection`, `electric_client` on Hex, and `y-electric`. Those libraries hold the value. The server behind them is replaceable.

Restdis already has almost every expensive part of this design. It has:

- a WAL reader (`restdis_buster`) that uses exactly one replication slot for the whole cluster, moves to another node if its node fails, spreads changes across availability zones, and continues from the last LSN after a restart;
- a three-layer cache for each tenant (ETS, then CubDB, then PostgREST) that copies its durable entries to other nodes;
- a reverse index that maps `(table, primary_key)` to the cache keys that contain that row, which is the same routing problem Electric solves with its shape filter;
- tenant configuration, API-key authentication, routing of tenants to nodes, and Prometheus and OpenTelemetry instrumentation.

Restdis is missing two things: the ordered shape log that Electric clients read, and the HTTP protocol that delivers it.

This RFC proposes that we build both. We will serve `GET /v1/shape` from `restdis_server` and back it with a new bounded context named `restdis_electric`. An application that already uses an Electric client library will then work against Restdis after it changes one base URL. Restdis will serve the log from its own cache layers. It will not need Electric's single-instance file store or an external CDN.

### Who asks for this

- **Customers who already run Electric.** They want this kind of sync without running a second stateful service, a second replication slot, and a CDN contract.
- **Restdis tenants who want live data.** They build dashboards, shared editing screens, and agent state. Today they call `PGRST.QUERY` on a timer, which wastes work and adds delay.
- **Teams that considered Electric and stopped.** Electric runs as a separate service, serves one tenant, and requires them to build an authentication proxy in front of it.

### Why it is worth doing

Electric argues that the hard parts of sync are partial replication, fan-out, and delivery. Restdis already solves fan-out and delivery for normal request and response traffic. It already pays the cost of reading the WAL. Building the shape log reuses that work for a second, more valuable access pattern. The alternative is to run a second system that reads the same database.

The client protocol is documented and stable, so we can test compatibility directly. The published Electric client libraries become our acceptance tests. We do not have to guess whether we are compatible. We can run their code against our server.

---

## Background

### The compatibility contract

This RFC succeeds only if Restdis is a drop-in replacement. We define that exactly:

> An application that uses `@electric-sql/client@^1`, `@electric-sql/react@^1`, or `@tanstack/electric-db-collection` continues to work after it changes the `url` option to point at Restdis. It changes no other code. It changes no dependency. It uses no fork.

Every item in Scope is subordinate to that sentence. Our internals will differ from Electric's in several places. Each difference must meet one of two conditions:

1. The client cannot observe it.
2. We reject the request when the client subscribes, with HTTP status `400` and a message that names the problem.

We must never accept a shape and then serve a log that quietly differs from what Electric would serve. A silent difference produces wrong data on the client, and the client has no way to detect it.

**We aim at a fixed version. We do not follow Electric's development.** We will implement the Electric 1.x protocol and the published major versions of the client libraries. We treat them as a frozen specification. We will not port protocol changes that Electric makes after we pin the version. We make no promise about future versions.

The reason is ownership. Electric's roadmap now belongs to Databricks and Neon. If we followed it, another company's release schedule would become a dependency of our own. We would pay that cost to help clients that already work. If a future Electric protocol version matters to us later, we will decide that in its own RFC.

This has a direct consequence for anyone moving to Restdis. **They migrate in one step.** They point their clients at Restdis, the clients resynchronise from `offset=-1`, and they then shut Electric down. They do not run both systems together. Running both against one database means two replication slots and two sources of WAL retention risk, and it gains them nothing. The resynchronisation uses the `409` path that every Electric client already implements. The cost of the migration is one snapshot for each shape.

### The protocol we must implement

These are the query parameters of `GET /v1/shape`. The Phase column shows when we build each one.

| Parameter | What it does | Phase |
| --- | --- | --- |
| `table` | Names the table. May include the schema. Required unless the client resumes with a handle. | 1 |
| `offset` | Sets the start position. `-1` starts from the beginning and triggers a snapshot. `0_inf` means the end of the snapshot. `{lsn}_{op_offset}` resumes at a position. `now` skips all history. | 1 |
| `handle` | Identifies the shape. Required whenever `offset` is not `-1`. | 1 |
| `live` | Asks the server to hold the request open until new data arrives. | 2 |
| `cursor` | Defeats stale caching when a live client reconnects. | 2 |
| `columns` | Selects which columns to return. Must include the primary key. | 2 |
| `where` | Filters rows with a Postgres SQL boolean expression. | 3 |
| `params` | Supplies values for the `$1` placeholders in `where`. | 3 |
| `replica` | `default` or `full`. Controls whether update and delete messages carry the complete old row. | 3 |
| `live_sse` | Uses Server-Sent Events instead of long-polling. | 4 |
| `log` | `full` returns the snapshot and then the changes. `changes_only` returns only the changes. | 5 |
| `secret` | Restricts direct access to holders of a shared secret. | 2 |

Responses carry these headers: `electric-handle`, `electric-offset`, `electric-up-to-date`, `electric-schema`, `cache-control`, `etag`, and, on a `409`, `location`.

The body is a JSON array of messages. There are two kinds.

- A change message: `{ key, value, old_value?, headers: { operation: "insert"|"update"|"delete", lsn?, op_position?, handle? } }`
- A control message: `{ headers: { control: "up-to-date" | "must-refetch" } }`. In `changes_only` mode there is also a `snapshot-end` message that carries the Postgres snapshot descriptor.

We use four status codes.

| Status | When we send it |
| --- | --- |
| `200` | We are returning data. We also send `200` when a live request times out. In that case the body holds only an `up-to-date` control message. |
| `400` | The shape definition is invalid. The table does not exist, the `where` clause does not parse or is not supported, or the column list omits the primary key. |
| `409` | The handle is no longer valid. The client must discard its data and start again. The `location` header carries a new handle. |
| `429` | The tenant has reached a configured limit. |

We also serve `DELETE /v1/shape`. It is available only when the `allow_shape_deletion` setting is on. It reuses the existing per-tenant cache flush.

### How Electric's parts map onto Restdis

| Electric component | What Restdis has now | What we must build |
| --- | --- | --- |
| `Electric.Postgres.ReplicationClient` | `RestdisBuster.Tailer` and `Wal.PGOutput` | Set `REPLICA IDENTITY FULL` on the tables that shapes read. Carry the complete old and new row through `Wal.Event`. |
| `ShapeLogCollector` | `RestdisBuster.Dispatcher` | Add a third dispatch target, `:shape_append`, beside invalidate and refresh. |
| `Electric.Shapes.Consumer` | Nothing equivalent | `RestdisElectric.Consumer`. One process for each active shape. |
| `Electric.Shapes.Filter` | `Restdis.Cache.ReverseIndex` solves the same problem with a different key | `RestdisElectric.Filter`, mapping `(table, column, constant)` to a set of shape handles. |
| `PureFileStorage` | `Restdis.Cache.DiskCache` and ETS | `RestdisElectric.Log`. See "How we store the shape log". |
| Snapshot inside a read-only transaction | `Restdis.Cache.Origin.PostgREST` | A new snapshot reader. See "How we keep the snapshot and the log consistent". |
| CDN request collapsing | The Restdis cache layers and per-zone fan-out | Do the collapsing inside Restdis. Stay compatible with a CDN as well. |
| An authentication proxy that the user writes | `RestdisServer.HTTP.Plug.Auth` and tenant configuration | Nothing. Restdis already binds shape definitions to an API key. |

### The `restdis_electric` bounded context

All of this new work goes into one new umbrella application, `restdis_electric`, under the `RestdisElectric` module namespace. It is a bounded context in its own right. It is not a folder of features inside `restdis_server`.

The context owns the meaning of the Electric protocol. That includes shape definitions, handles, the shape log and its index, the filter index, the per-shape processes, snapshot reading, and the parsing and evaluation of `where` clauses. It decides what a shape is, what its log contains, and when a handle stops being valid.

The context does not own HTTP. It knows nothing about status codes, headers, or connections.

**Which way the dependencies point.** `restdis_electric` depends on `restdis`, which gives it cache, storage, and tenant primitives. It depends on no other application in the umbrella. `restdis_buster` pushes changes into it. `restdis_server` reads from it. Neither of those appears in its dependency list.

```
restdis_buster ──push──▶ ┌─────────────────┐ ◀──pull── restdis_server
                         │ restdis_electric│              (HTTP)
                         └────────┬────────┘
                                  │ depends on
                                  ▼
                               restdis
```

This gives us a practical benefit. We can start the context and run its full test suite without an HTTP server and without a WAL reader.

**The public API.** Three modules are public. Everything else stays inside the context.

- `RestdisElectric` is what the HTTP layer calls. It turns a definition into a handle, reads a range of the log, waits for new data, and deletes a shape. It returns domain values such as `{:ok, messages, offset}`, `{:error, :must_refetch, new_handle}`, and `{:error, {:unsupported_where, expr}}`. It never returns a `Plug.Conn` and never returns an HTTP status code.
- `RestdisElectric.Definition` builds and validates a shape definition. `restdis_server` uses it to build definitions from tenant configuration.
- `RestdisElectric.WAL` receives decoded changes from `restdis_buster`. It also tells the WAL reader which changes it has written to disk.

**How we enforce the boundary.** `apps/restdis/mix.exs` already defines a `check.boundary` task. It reads a list named `@umbrella_namespaces` and fails the build if the `restdis` library mentions any of those namespaces. We will add `RestdisElectric` to that list. We will also add the opposite check inside `restdis_electric`: it must not mention `RestdisServer`, `RestdisBuster`, `RestdisRepo`, or `RestdisReplicator`.

One note while we are in that file. The list today is `RestdisServer`, `RestdisBuster`, and `RestdisRepo`. `RestdisReplicator` is missing, so the current check does not catch every violation. That is a small fix and belongs in its own change.

**Why this is a separate context and not part of `restdis_server`.** There are three reasons, in order of weight.

1. The shape log holds state and lives for a long time. `restdis_server` handles requests and returns responses. Processes with such different lifetimes should not share one supervision tree.
2. Two different applications drive this code. The WAL reader writes to it and the HTTP server reads from it. It belongs to neither one.
3. The Electric protocol is a specification that another team controls. If we keep it in one application, a protocol change touches one application and one test suite. It cannot affect the Redis protocol path or the PostgREST path.

### How we connect it to `restdis_server`

`restdis_server` gains one dependency, `{:restdis_electric, in_umbrella: true}`, and one thin adapter. The adapter is the only place in the whole system that knows Electric's HTTP contract.

1. **Routes.** `RestdisServer.HTTP.Endpoint` gains `get "/v1/shape"` and `delete "/v1/shape"`. They sit beside the existing `/pgrst/query` and `/pgrst/policy` routes.
2. **Authentication.** Both routes use the existing `RestdisServer.HTTP.Plug.Auth` to identify the tenant, exactly as `/pgrst/query` does today.
3. **The adapter.** A new module, `RestdisServer.HTTP.Electric`, does all the translation. It converts query parameters into a `RestdisElectric.Definition`. It converts domain results into a status code, headers, and a JSON body. Every Electric header and every status code appears in this module and nowhere else.
4. **Transport.** Holding a long-poll open and framing Server-Sent Events are jobs for `restdis_server`. Both use the same `await` function in the context's public API. The context reports that new data exists at a given offset. The server decides what to do with that fact.
5. **Supervision.** The context provides `child_spec/1`, and the host application starts it. `Restdis.Cache` already works this way: the `:restdis` library declares no application callback, so adding it as a dependency starts no processes. `restdis_electric` follows the same rule.
6. **Metrics.** The context emits telemetry events. `RestdisServer.Metrics` attaches to them and exports them. The context therefore does not depend on the server's Prometheus setup.

There is a simple test of whether this separation is real. Delete the two routes and the adapter module. `restdis_electric` must still compile, and its tests must still pass.

### How we store the shape log

Electric learned a lesson here that we should not have to learn again. Electric version 1.0 stored shape logs in CubDB, a general-purpose key-value store. Version 1.1 replaced it with a storage engine built for this one job. The published measurements on SSD are roughly 102 times faster writes and 73 times faster reads. The rewrite also let readers work without blocking the writer, which enabled read-only replicas and deployments with no downtime.

This matters to us because the Restdis Phase 1 PRD already records that CubDB write throughput is unmeasured.

So we build `RestdisElectric.Log` as a purpose-built append-only store from the start. It maps onto the three Restdis layers as follows.

1. **Layer 1, ETS, for hot data.** This holds the chunk we are currently writing and the metadata for each shape: current offset, handle, schema, and the set of waiting clients. Live long-polls read only from here. A live client never causes a disk read.
2. **Layer 2, files on NVMe, for durable data.** When a chunk reaches its size limit we close it. A closed chunk never changes again. Beside the chunks we keep a sparse index that records where each chunk starts. To read from an offset, we search the index for the right chunk and then scan that chunk. Because both the log and the index only ever grow at the end, readers never block the writer, and we need no locks. CubDB still holds shape *metadata*, which is small and needs transactions. It does not hold log bodies. Restdis plans to replace CubDB, so `RestdisElectric.Log` must reach it only through the `Restdis.Cache` public API. The replacement then changes one context.
3. **Layer 3, the origin.** PostgREST, or the read replica that the tenant configured, serves the initial snapshot one page at a time. This reuses `Restdis.Cache.Origin` and the tenant's existing API key.

Closed chunks never change, so we can copy them. The existing replication path for durable cache entries can push hot chunks to other nodes. Any node in the region can then answer a resume request without asking another node for the data.

**One storage layer, shared with `restdis_replicator`.** We model the shape log as key-value storage. We do not build a second, parallel store. The operation at offset N is a value stored under a key derived from N, so the log is a continuous range of keys. Restdis would otherwise have three storage models: cached query responses, replicated key-value datasets, and shape logs. Instead it has one substrate with three access patterns. When we replace CubDB, we perform one migration rather than three.

Retention follows from that model. Each shape keeps a **configurable number of recent operations**. The tenant sets this value for each shape, and a tenant-level default applies otherwise. We delete keys that fall outside that window. Four consequences follow, and they deserve to be stated plainly.

- **A client that resumes below the window gets a `must-refetch`.** Its offset no longer exists, so we return `409` and it starts again from `-1`. The protocol already defines this path. We are adding one more reason to use it.
- **The window controls cost and reconnection speed. It does not control correctness.** A large window lets clients reconnect cheaply after a long time offline. A small window bounds disk use. Neither changes what a client sees once it has caught up.
- **The tenant chooses the size, and a wrong choice is visible.** If the window is too small, clients that connect intermittently will resynchronise again and again, which is expensive. This appears directly in the `409` rate. Phase 2 already requires us to report `409` counts by cause, so an operator can diagnose a badly sized window instead of guessing.
- **This differs from Electric on purpose.** Electric keeps an unbounded log and compacts it. Compaction lets any client resume however old its offset is, but the log grows without limit, and the compaction routine must preserve the order in which keys were created and deleted. Truncation gives up the old tail and gains a hard limit on disk use and much simpler code. For a platform with per-tenant limits, the hard limit is worth more. Both designs satisfy the protocol, because the only thing a client can observe is whether its own offset still exists.

**A durability rule we take from Electric.** We must not call `fsync` on every write, because that is too slow. We must also not lose changes. The rule that satisfies both is this: only tell Postgres that we have processed the WAL up to an LSN after we have written every change up to that LSN to disk. If Restdis crashes, Postgres replays from the last confirmed LSN.

This changes `RestdisBuster.Infra.LSNStore`. Today it confirms an LSN when it dispatches the change. Once shapes exist, it must wait until every active shape has written the change. If it does not wait, a crash loses changes that Postgres believes we have handled.

### How we keep the snapshot and the log consistent

This is the largest difference between our design and Electric's, and it is the part most likely to produce subtle bugs. It deserves care.

The problem is the join between two sources of data. The snapshot reads the table as it exists now. The log carries changes as they happen. A row must not be lost between the two, and, ideally, it should not appear twice.

Electric solves this with information that only a direct Postgres connection provides. It runs the snapshot query inside a read-only transaction and records the result of `pg_current_snapshot()`, which reports which transactions were running at that instant. It then discards any buffered WAL transaction that the snapshot already contains.

Restdis cannot do that. Our origin is PostgREST, which does not expose transaction identifiers. Our WAL reader sees transaction identifiers but does not tie them to a shape's snapshot.

Restdis therefore uses **LSN bracketing with idempotent operations**. It works in three steps.

1. Record `L0`, the WAL position at this moment, and start buffering every change that matches the shape.
2. Read the snapshot from PostgREST, one page at a time. Write each row into the log as an `insert`, up to the `0_inf` marker.
3. Replay the buffer from `L0` onward, appending after `0_inf`.

Any transaction that commits between `L0` and the snapshot read appears twice: once from the snapshot, once from the replay.

That duplication is safe, and the reason is worth spelling out. Each operation is keyed by row. `insert` sets a key, `update` merges into a key, and `delete` removes a key. Applying `insert` twice for the same row produces the same result as applying it once. Deleting a row that is already absent does nothing. So the client reaches the same state either way. Electric depends on this same property in its `changes_only` mode, where it tells clients to treat inserts as upserts.

The requirement we must meet is therefore narrow and we can meet it: **the log must never omit an operation, and every operation must be safe to apply more than once.** Our design satisfies both.

The trade-offs, stated directly:

- **What it costs.** A limited number of duplicated operations at the snapshot boundary. The cost is extra bytes, not incorrect data. The number depends on how many writes occur while the snapshot runs.
- **What we gain over Electric.** We can take the snapshot through PostgREST. The snapshot then obeys row-level security, follows the tenant's read-replica setting, and reuses the origin code we already have. Electric's approach needs a second, privileged connection pool directly to Postgres.
- **An exact path where it is available.** If a tenant has configured a direct Postgres pool, `RestdisElectric.Snapshotter` can use Electric's exact method instead and produce fewer duplicates. The log it writes is the same. This arrives in Phase 5.
- **What the client sees.** For `log=full`, nothing. For `log=changes_only`, Electric sends the snapshot descriptor to the client in the `snapshot-end` message so the client can skip duplicates itself. We cannot produce that descriptor without a direct connection. So `changes_only` requires the direct path, and we return `400` when it is not configured.

### How we evaluate `where` clauses

Electric parses and evaluates the `where` clause inside its own process, once for every row that arrives from the WAL. We must do the same. The alternative is to ask Postgres to test the predicate for every row and every shape, which would move the load back onto the database and defeat the purpose of the system.

Our approach, ordered by how much risk each step removes:

1. **Parse with [`datafusion-sqlparser-rs`](https://github.com/apache/datafusion-sqlparser-rs) through Rustler.** We do not write our own parser. Its `PostgreSqlDialect` covers the whole grammar we accept. It is fast enough that parsing cost does not matter, because we parse only when a client subscribes. It is written in safe Rust, so a malformed expression returns an error rather than corrupting memory inside the virtual machine. It parses more than we evaluate, which is the safe direction: our own check over the parse tree decides what we accept, so the parser cannot widen our supported set by accident.
2. **Evaluate exactly the subset Electric documents.** That is: comparison, logical, arithmetic, and bitwise operators; `LIKE` and `ILIKE`; the array operators `@>`, `<@`, and `&&`; null and boolean tests; `IN` and `NOT IN`; `BETWEEN`; `ANY` and `ALL`; and the functions `lower`, `upper`, `coalesce`, `greatest`, and `least`. We do not support, and neither does Electric: JSONB operators, full-text search, geometric types, network address types, range operators, and functions whose result changes between calls, such as `now()` and `count()`.
3. **Reject early.** Anything outside the subset returns `400` when the client subscribes, and the message names the part we cannot handle. We must never accept a shape and then filter it incorrectly. An incorrect filter sends one tenant's rows to another tenant.
4. **Subqueries come in Phase 6.** A clause such as `field IN (subquery)` requires us to track a second table, because rows can enter and leave the shape when the subquery result changes even though the row itself did not change. Until we build that, these clauses return `400`.

**Rows that enter and leave a shape.** We must handle this from Phase 3. It is not an optimisation; without it the client's data is wrong. When an update causes a row to start matching the filter, we write an `insert`, because the client has never seen that row. When an update causes a row to stop matching, we write a `delete`, because the client must remove it, even though the row still exists in Postgres.

This is why we require `REPLICA IDENTITY FULL` on these tables. With the default setting, Postgres puts only the primary key in the WAL record for an update or a delete. We need the complete previous row, because we must test the filter against the row as it was before the change.

### Fan-out, and where we differ on purpose

Electric tests every shape's filter against every row that arrives. To keep that affordable, it indexes shapes by the constant in clauses of the form `field = constant`. With that index its throughput stays near 5,000 changes per second no matter how many shapes exist. Without it, throughput falls roughly in proportion to the number of shapes.

`RestdisElectric.Filter` uses the same idea, and the existing reverse index shows that the team can build this kind of index. Restdis adds two advantages that Electric cannot have.

- **Routing tenants to nodes filters first.** Each node owns a set of tenants, so it only tests shapes that belong to those tenants. Electric runs as a single instance and has no equivalent.
- **Per-zone fan-out already limits traffic.** One message crosses to each availability zone for each change, whatever the number of shapes.

Now the difference that matters most, because it is the main argument for building this on Restdis.

Electric's scaling story depends on a CDN. When a million clients long-poll the same shape at the same offset, the CDN recognises one resource and sends one request to Electric. Without that collapsing, Electric holds a million connections itself.

Restdis does this collapsing inside the server. All live requests for the same `(tenant, handle, offset)` join one waiting set in ETS, and one append wakes all of them. Resume requests for settled offsets read closed chunks from the cache layers, which are already copied across nodes.

**So a CDN becomes an optimisation rather than a requirement.** We still send correct `cache-control` and `etag` headers, so a CDN in front of Restdis still collapses requests. We are compatible with that deployment without depending on it. This matters most for self-hosted and single-region deployments, which is exactly where Electric's design is weakest.

### Authentication

Electric includes no authentication. It expects every production deployment to place a proxy in front of it. That proxy authenticates the request and then sets the shape definition itself, so the client can send only protocol parameters such as `offset`, `handle`, `live`, and `cursor`. Electric documents this pattern, but each team must build it.

Restdis has these parts already. `RestdisServer.HTTP.Plug.Auth` identifies the tenant from an API key, and configuration is per tenant. So the endpoint offers two modes.

- **Gatekeeper mode.** Tenant configuration names each shape definition. The client sends a shape name and protocol parameters only. We reject `table`, `where`, and `columns` from the client.
- **Open mode.** The client supplies the shape definition. A `queryable_columns` allow-list limits which columns it may reference, and an optional shared secret limits who may call at all.

Both modes ship. Each tenant configures which one applies to it. This is a per-tenant setting, not a platform-wide policy. Gatekeeper is the default, because the failure caused by the wrong default is serious: a tenant would accept arbitrary filters written by its own clients without intending to.

Both modes produce identical logs. Gatekeeper mode is what makes it safe to expose this endpoint to many tenants at once, which Electric cannot do at all.

### Handles, offsets, and cache keys

**Handles.** Electric computes the handle by hashing the shape definition and formatting the result as `{hash}-{epoch_ms}`. Clients treat it as opaque text. We must keep that format.

We must not use `:erlang.phash2/1` to compute it. `Restdis.Cache.Key` uses `phash2` today, which is correct for a cache key that lives only in one running process. A handle is different: we write it to disk, and clients hold it across our deployments and across Erlang upgrades. It must therefore be stable forever. We will use a truncated SHA-256 of the canonical form of the definition.

We compute the hash over `(tenant_id, definition)`. Two tenants that define the same shape must not share one log. The tenant part never appears in the handle we return.

**Offsets.** The format is `{lsn}_{op_offset}`. The first part is the Postgres LSN as an integer. The second is the position of the operation inside its transaction.

**Cache keys.** We add a `:shape` scope to `Restdis.Cache.Key`. Shape chunks then share the addressing scheme used by cached PostgREST responses, and they inherit the existing per-tenant limits, metrics, and flush behaviour.

### Every reason we return `409`

A `409` tells the client to discard everything and start again. It is the only signal Electric clients understand for that. So every event that destroys or invalidates a log must produce one.

| Cause | Where it comes from in Restdis |
| --- | --- |
| The replication slot was recreated or invalidated | The slot configuration in `RestdisBuster`. Losing the slot invalidates every shape. |
| The table's schema changed | The existing DDL event trigger for `DROP TABLE`, plus a periodic check that compares cached table metadata against the real schema. Electric runs the same check every 60 seconds, because some changes produce no notification in the WAL. |
| The shape was evicted because the tenant hit a limit | `RestdisElectric`'s LRU eviction: when a tenant at `max_shapes` subscribes to a new shape, the least-recently-accessed idle shape is evicted (`RestdisElectric.ShapeRegistry.least_recently_used/1`, `RestdisElectric.Log.waiting?/2`) to make room, reusing `delete_shape/2` so the evicted shape's next resume finds no log and `must_refetch`es with cause `shape_limit_exceeded`. If every shape is currently busy (a client is blocked in a live long-poll on it), there is nothing safe to evict and the subscribe is rejected with `429` instead. |
| The client resumed below the retained window | Log truncation, described in "How we store the shape log". |
| Someone called `DELETE /v1/shape` | New, and only when `allow_shape_deletion` is on. |
| The Postgres timeline or system identifier changed | The slot configuration check that runs when we connect. |

### The boundary of compatibility: clients only

Our compatibility stops at the HTTP protocol. We configure, deploy, and operate Restdis as Restdis. It keeps its own environment variables, its own storage layout, its own `/metrics` endpoint, and its own tenant configuration. We read no `ELECTRIC_*` environment variable. We do not try to look like Electric to an operator.

The reason is that operational compatibility gains us nothing and costs us a permanent constraint. The people we are helping are application developers who do not want to rewrite working client code. The operator, by contrast, chose to deploy Restdis. Supporting `ELECTRIC_STORAGE_DIR` or `ELECTRIC_MAX_SHAPES` would tie our internals to Electric's operational model: one instance, one storage directory, one flat limit on shapes. That model is exactly what per-tenant limits and tenant routing replace.

We will help operators migrate with documentation instead: a table that shows which Restdis setting serves the same purpose as each Electric setting.

---

## Scope

**In scope:**

- The `restdis_electric` umbrella application, a standalone bounded context under the `RestdisElectric` namespace. It owns shape definitions, handles, the chunked append-only log, the offset index, the filter index, the per-shape processes, snapshot reading, and `where` clause evaluation.
- Its integration into `restdis_server`: `GET` and `DELETE /v1/shape` on `RestdisServer.HTTP.Endpoint`, behind the existing authentication plug, with one adapter module that owns the whole HTTP contract.
- The initial snapshot through PostgREST, made consistent by LSN bracketing and idempotent operations.
- Live updates by long-polling, with request collapsing inside the server, and Server-Sent Events as a second transport.
- Parsing and evaluating `where` clauses over exactly the subset Electric documents, including rows that enter and leave a shape.
- A shape filter index whose throughput does not fall as the number of shapes grows.
- Gatekeeper authentication, which binds shape definitions to an API key on the server.
- A conformance test suite that runs the published Electric client libraries against Restdis.

**Out of scope:**

- **Operational compatibility.** No `ELECTRIC_*` environment variables, no Electric storage layout, no Electric-shaped configuration. Compatibility covers clients only.
- **Any `where` clause construct outside Electric's documented subset**, even where it would be easy to add. Supporting more than Electric is itself a compatibility failure: a shape that works on Restdis and fails on Electric makes the migration one-way.
- **Writes.** We limit our scope exactly as Electric does. There is no write path, no conflict resolution, and no CRDTs. Writes continue to go to PostgREST.
- **Shapes that span several tables.** Electric does not support them either.
- **Changing a shape definition in place.** A different definition produces a different handle, as in Electric.
- **Electric's pre-2024 protocol, its DDLX layer, and its client-side SQLite storage.** Electric abandoned all of it.
- **Server-side support for PGlite or `y-electric`.** These run in the client. They work if our log is correct. We will test them, but we build nothing for them.
- **Origins other than Postgres.**
- **Replacing `PGRST.QUERY`.** This API is an addition. The Redis protocol surface does not change.

---

## Phase 1: The shape log and reads without live updates

This phase delivers a durable shape log and a `GET /v1/shape` that serves a snapshot and resumes from an offset. It has no live updates and no filtering.

1. Add `restdis_electric` as the fifth umbrella application. It depends on `restdis` only. Add a `check.boundary` task that fails if it mentions any other umbrella namespace, and add `RestdisElectric` to the list that `restdis` checks against.
2. Provide `RestdisElectric.child_spec/1` and let the host application start it. Declare no application callback, following `Restdis.Cache`.
3. Write `RestdisElectric.Definition`, which holds the table, columns, filter, and parameters, and `RestdisElectric.Handle`, which computes a truncated SHA-256 for each tenant and formats it as `{hash}-{epoch_ms}`.
4. Write `RestdisElectric.Log`: append to the open chunk, close a chunk when it reaches its size limit, append to the sparse index when a chunk closes, and read by searching the index and then scanning one chunk.
5. Write `RestdisElectric.Offset`: encode and decode `-1`, `0_inf`, `now`, and `{lsn}_{op_offset}`, and order them. The LSN crosses the context boundary as a plain integer, so this module does not depend on `RestdisBuster.Infra.LSN`.
6. Write `RestdisElectric.Snapshotter`: record `L0`, read the shape's rows from PostgREST page by page through `Restdis.Cache.Origin`, and append each row as an `insert` up to `0_inf`.
7. Add the `:shape` scope to `Restdis.Cache.Key` so chunks inherit the per-tenant limits and flush behaviour.
8. Expose the read API on `RestdisElectric`: turn a definition into a handle, read a range of the log, and delete a shape. Return domain values only.
9. Add `{:restdis_electric, in_umbrella: true}` to `restdis_server`, start its `child_spec` in `RestdisServer.Application`, and add `get "/v1/shape"` behind the existing authentication plug.
10. Write `RestdisServer.HTTP.Electric`: convert parameters into a definition, and convert domain results into a status code, headers, and a JSON body. This includes `409` with a `location` header for an unknown or invalid handle, and `400` for an unknown table or a column list that omits the primary key.

**We are done when:**

- A shape over a 10,000-row table returns the complete snapshot across several pages, and joining those pages reproduces the table exactly.
- Resuming at any offset inside the snapshot returns exactly the operations after it, with none missing and none reordered.
- A request at a settled offset returns an identical body and the same `etag` after a restart.
- Log chunks survive a simulated node restart and serve their data on recovery.
- `mix check.boundary` passes in both directions: `restdis` does not mention `RestdisElectric`, and `restdis_electric` does not mention any other umbrella namespace.
- The `restdis_electric` test suite passes with neither `restdis_server` nor `restdis_buster` running.
- A property test shows that, for any series of appends and any resume offset, replaying from that offset produces the same final data as replaying from `-1`.

**Risks:**

- The chunked file store is new code, and every read and write passes through it. Electric's published numbers say the general-purpose store fails at this job, so not building it carries the larger risk. We must benchmark against the existing Phase 1 target of 10,000 writes per second per tenant before we start Phase 2.
- The handle must stay stable across deployments. If anything that varies by Erlang version, by node, or by map ordering reaches the hash function, every client breaks at once. The function that produces the canonical form needs its own property test.

---

## Phase 2: Live updates and proof of client compatibility

This phase delivers real-time updates and the first end-to-end evidence that Electric clients work against Restdis.

1. Expose `RestdisElectric.WAL`, which receives a decoded change and reports when it has written it to disk. Add a `:shape_append` target in `RestdisBuster.Dispatcher` that calls it. The dependency points from the WAL reader into the context, never the other way.
2. Write `RestdisElectric.Consumer`: one process for each active shape. It appends matching changes to its log and hibernates when idle.
3. Check that each table a shape reads has `REPLICA IDENTITY FULL`. If it does not, return `400` with a message that says how to fix it.
4. Add `RestdisElectric.await/3` to the public API. It waits until the log passes a given offset or a deadline expires, and returns domain values only.
5. Build long-polling in `RestdisServer.HTTP.Electric` on top of `await/3`. Hold the request until data arrives or the timer expires. On a timeout, return `200` with only an `up-to-date` message.
6. Collapse duplicate live requests inside the server. Every client waiting on the same `(tenant, handle, offset)` joins one waiting set, and one append wakes all of them.
7. Support the `columns` parameter, and check that the list includes the primary key.
8. Support the shared secret and gatekeeper mode in `restdis_server`. Read shape definitions from tenant configuration by name, and reject definition parameters sent by the client.
9. Change `RestdisBuster.Infra.LSNStore` so that it confirms an LSN to Postgres only after `RestdisElectric.WAL` reports that it has written every change up to that point.
10. Connect per-tenant shape eviction to a `409` instead of dropping the shape silently.
11. Emit telemetry from the context and export it from `RestdisServer.Metrics`: active shapes per tenant, append latency, number of waiting clients, how many requests each append serves, and `409` counts by cause.

**We are done when:**

- `ShapeStream` and `Shape` from `@electric-sql/client` work end to end against Restdis with only the `url` changed, and `useShape` from `@electric-sql/react` redraws when the database changes.
- A committed Postgres write reaches a waiting live client within 2 seconds.
- 1,000 concurrent live requests on one shape produce one wake-up and one response body.
- Killing the node that holds the WAL reader loses no operation. After another node takes over and resumes from the last LSN, every client's data matches Postgres.
- A shape evicted by a tenant limit produces a `409` with a usable `location`, and the client recovers to correct data.

**Risks:**

- Live long-polls hold connections open. Collapsing turns this into a question of memory rather than sockets, but we must add a per-tenant limit on waiting clients before we load test.
- The confirmed LSN now depends on the slowest shape. A stuck shape stops us confirming, which makes Postgres retain WAL and can fill its disk. Electric documents the same hazard. We need a watchdog that stops a shape that falls too far behind and returns `409` to its clients. We trade one shape's resynchronisation for the health of the cluster.

---

## Phase 3: Filters, and rows that enter and leave a shape

This phase delivers partial replication, which is the feature that makes shapes worth having.

1. Add `datafusion-sqlparser-rs` through Rustler. Parse `where` with `PostgreSqlDialect`, and parse only when a client subscribes.
2. Write `RestdisElectric.Eval`, which evaluates exactly the documented subset listed earlier in this document.
3. Reject anything outside that subset when the client subscribes. Return `400` and name the construct we do not support.
4. Support `params` and `$1` placeholders. Never build the expression by joining strings.
5. Handle rows that enter and leave the shape. Test the filter against the row before the change and after it. Write an `insert` when it starts matching and a `delete` when it stops matching.
6. Support `replica=full`, so update and delete messages carry `old_value`.
7. Write `RestdisElectric.Filter`, a hash index from `(table, column, constant)` to a set of shape handles. Index the clause forms `field = constant`, `constant = field`, `field IN list`, `array_field @> constant`, and `const = ANY(array_field)`, including combinations joined by `AND` and `OR`. When a clause mixes indexed and non-indexed parts, use the index first and test the remaining shapes one by one.
8. Add metrics: how often the index answers, how many shapes we test for each change, and throughput against shape count.

**We are done when:**

- Every expression in the supported subset produces the same decision as Postgres evaluating the same expression. We prove this with a test that runs both against a live Postgres and compares.
- Every expression outside the subset returns `400` when the client subscribes. We never accept a shape and then filter it incorrectly.
- An update that moves a row into a shape produces an `insert`, and one that moves it out produces a `delete`. In both cases the client's data matches a fresh snapshot.
- Throughput stays at the rate measured in Phase 2 as the number of indexed shapes rises from 10 to 1,000. We measure and document what happens with non-indexed clauses.

**Risks:**

- A difference between our evaluation and Postgres's is both a correctness bug and a security bug. If we return true where Postgres returns false, we send one tenant's row to another. The comparison test against a real Postgres is the gate for this phase, not an extra.
- Rustler runs the parser inside the Erlang virtual machine, so a slow parse blocks a scheduler. Parse on a dirty CPU scheduler, limit the size of the input, and parse only when a client subscribes. Never parse while processing the WAL. Safe Rust removes the memory-safety risk. It does not remove this one.
- `datafusion-sqlparser-rs` is a SQL parser, not Postgres. Its parse tree may disagree with Postgres about an unusual literal, cast, or operator precedence. The comparison test exists to find those cases. We resolve each one by accepting less, never by guessing.

---

## Phase 4: The second transport, and cache behaviour

This phase delivers the remaining transport and proves that caching behaves correctly from end to end.

1. Support `live_sse=true` in `RestdisServer.HTTP.Electric`. Frame Server-Sent Events and send a keep-alive comment every 21 seconds. Use the same `await/3` that long-polling uses. No transport detail enters the context.
2. Support the `cursor` parameter, which prevents a stale cached response when a live client reconnects.
3. Send `cache-control` with `max-age` and `stale-while-revalidate` that match Electric's meaning: settled offsets never change, live responses expire quickly.
4. Test behind Nginx, Caddy, and one commercial CDN. Confirm that they collapse duplicate requests and that none of them caches a live response as permanent.
5. Confirm the client's documented fallback works against us. The client gives up on Server-Sent Events and returns to long-polling after several quick disconnections, which happen behind a proxy that buffers responses.
6. Load test with 100,000 concurrent live clients across 100 tenants and 1,000 shapes, with and without a CDN. Measure memory, 99th-percentile latency, and how many requests reach the origin.

**We are done when:**

- Both transports deliver the same sequence of messages for the same shape.
- Without a CDN, 100,000 concurrent live clients see flat memory use and 99th-percentile propagation under 2 seconds.
- With a CDN, roughly one request per shape per interval reaches Restdis, whatever the number of clients.
- No cache layer ever serves stale data for a settled offset. We prove this with a test that writes to the database during a cached read.

**Risks:**

- Cache headers are easy to get subtly wrong, and a wrong header is severe. If we mark a live response as permanent, a cache can serve it forever and the client never advances. Every combination of headers needs its own test.

---

## Phase 5: Direct Postgres snapshots and `changes_only`

This phase removes the duplicate operations at the snapshot boundary for tenants that have a direct Postgres connection, and adds the remaining `log` mode.

1. Add an optional direct Postgres pool for each tenant, used only for snapshots and separate from the replication connection.
2. Implement the exact method: run the snapshot in a read-only transaction, record `pg_current_snapshot()`, and skip buffered transactions that the snapshot already contains.
3. Once we have logged the first transaction that started after the snapshot, stop comparing transaction identifiers for that shape. This also avoids the problem of 32-bit identifiers wrapping around.
4. Support `log=changes_only`, and send the snapshot descriptor in the `snapshot-end` message. Return `400` when the tenant has no direct pool.
5. Record which method each tenant uses, and expose it as a metric.

**We are done when:**

- On the direct path, no row appears both in the snapshot and as an early logged insert.
- On the PostgREST path, we measure the duplicates, show they are bounded, and prove that clients reach the same final data.
- Clients using `changes_only` build the same data as clients using `full` for the same shape.

**Risks:**

- Two snapshot methods mean two code paths that must behave identically. They must share the same append interface and run against the same property tests.

---

## Phase 6: Subqueries and production readiness

1. Support `field IN (subquery)`. Track the second table, so rows enter and leave the shape when the subquery result changes even though the row itself did not change. Do this incrementally, including inside `AND`, `OR`, and `NOT`.
2. Compare cached table metadata against the real schema every 60 seconds, and invalidate affected shapes. This catches changes that produce no notification in the WAL.
3. Enforce per-tenant limits on the number of shapes, the bytes each log may use, and the number of waiting clients. Return `429` with a message the operator can act on.
4. Extend the Grafana dashboard: shapes per tenant, append latency, delay from write to client, `409` counts by cause, requests served per append, and log disk use per tenant.
5. Truncate each log to its configured length, per shape with a tenant default. Return `409` to any client that resumes below the retained window.
6. Publish a migration guide for client developers and a compatibility table that states exactly which protocol features and which `where` constructs we support. Include a documentation-only table that maps Electric's operational settings to their Restdis equivalents.
7. Run the conformance suite in CI against pinned versions of the published Electric client libraries, and block merges when it fails.

**We are done when:**

- Archiving a parent row removes its children from a subquery-filtered shape incrementally, with no `409`.
- Truncation holds each log at its configured length under sustained writes. A client resuming inside the window continues normally. A client resuming below it receives a `409` and recovers correctly.
- The conformance suite passes in CI and fails the build when we break something.
- We have published the compatibility table, and every entry marked unsupported corresponds to a `400` at subscription time rather than a silent difference.

---

## Compatibility table (target state after Phase 6)

| Capability | Electric | Restdis | Notes |
| --- | --- | --- | --- |
| `ShapeStream` and `Shape` from `@electric-sql/client` | Yes | Yes | The client changes only its URL. |
| `useShape` from `@electric-sql/react` | Yes | Yes | Works through the client library. |
| `@tanstack/electric-db-collection` and `useLiveQuery` | Yes | Yes | Works through the client library. |
| `y-electric` | Yes | Yes | Runs in the client. A correct log is enough. |
| `electric_client` on Hex, `Phoenix.Sync`, shapes derived from Ecto queries | Yes | Yes | Over HTTP only. We do not offer Electric's embedded mode. |
| Live updates by long-polling | Yes | Yes | Phase 2. |
| Live updates by Server-Sent Events | Yes | Yes | Phase 4. |
| `where` clauses in the documented subset | Yes | Yes | Phase 3, tested against a live Postgres. |
| `where` clauses containing subqueries | Yes | Yes | Phase 6. |
| `columns`, `replica`, and `params` | Yes | Yes | Phases 2 and 3. |
| `log=changes_only` with the snapshot descriptor | Yes | Partly | Needs a direct Postgres pool. Returns `400` otherwise. |
| Shapes spanning several tables | No | No | Neither system supports this. |
| Changing a shape definition in place | No | No | Neither system supports this. |
| Log retention | Unbounded, with compaction | Configurable length, with truncation | Compatible: resuming below the window uses the existing `409` path. |
| Writes and conflict resolution | No | No | Both exclude this deliberately. |
| Several tenants on one deployment | No | Yes | Restdis separates tenants already. |
| Built-in authentication | No | Yes | The operator does not build a proxy. |
| Needs a CDN to reach scale | Yes | No | Restdis collapses requests itself. A CDN remains optional. |
| Scaling reads across machines | Read replicas only | Yes | Tenant routing plus copied chunks. |
| Replication slots used | One for each Electric instance | One for the cluster, shared with cache invalidation | Reuses the existing WAL reader. |

---

## Open questions

| # | Question | Answer |
| --- | --- | --- |
| ~~1~~ | ~~Do shape logs share the existing per-tenant CubDB limit?~~ | **Resolved.** They get their own limit. Shape logs grow and expire differently from cached responses, and one shared limit would let a large shape evict hot cache entries. CubDB holds shape metadata only, so this does not deepen our dependency on a store we plan to replace. |
| ~~2~~ | ~~Which SQL parser do we use?~~ | **Resolved.** `datafusion-sqlparser-rs`, through Rustler. |
| ~~3~~ | ~~Is gatekeeper mode the only mode on the managed platform?~~ | **Resolved.** Both modes ship, and each tenant configures which one applies. Gatekeeper is the default. |
| ~~4~~ | ~~How do shapes relate to the always-live datasets in `restdis_replicator`?~~ | **Resolved.** They share one storage layer. We model the shape log as key-value storage with a configurable number of retained operations. See "How we store the shape log". |
| 5 | How does a tenant already running Electric migrate? | In one step. Point the clients at Restdis and let them resynchronise from `offset=-1`. |
| ~~6~~ | ~~Do we follow Electric's protocol after the Databricks acquisition?~~ | **Resolved.** No. Electric 1.x and the published client majors are a fixed target. |
