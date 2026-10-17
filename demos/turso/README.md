# Postgres → Turso replication

`sync.mjs` keeps an embedded [Turso](https://github.com/tursodatabase/turso) database in step
with a Postgres table. It never connects to Postgres. Restdis reads every write from the
Postgres WAL and serves the table as an Electric shape; the worker follows that shape with the
stock `@electric-sql/client` and applies each insert, update and delete to a local Turso file
through `@tursodatabase/database`.

![Postgres to Turso replication demo](../../docs/demos/turso.gif)

## How it works

1. **Snapshot.** On first start the worker requests the `orders` shape from offset `-1` and
   writes every row into Turso.
2. **Live changes.** It then holds a live poll open on Restdis. Each Postgres write releases
   the poll with the change, and the worker applies the batch in one Turso transaction.
   `replica: "full"` makes Restdis send whole rows on update, so every insert or update is a
   plain upsert.
3. **Resume.** After each batch the worker stores the shape handle and offset in a
   `_restdis_sync` table inside the replica. A restarted worker resumes from there, so changes
   made while it was down are applied and nothing is copied twice.
4. **Refetch.** If Restdis answers `must-refetch` (the shape was rotated), the worker clears
   the table and takes a fresh snapshot.

## Running it

Bring up the stack in [`demos/videos`](../videos), which configures `orders` in replication
mode:

```sh
cd demos/videos
docker compose up -d --build
docker compose exec -T db psql -U postgres -f - < tenant.sql

cd ../turso
npm ci
node sync.mjs                 # replica.db in this directory
```

Then write to Postgres and watch the worker apply each change:

```sh
psql postgres://postgres:postgres@localhost:5434/postgres \
  -c "insert into orders values (9, 'Katherine', 700, 'pending')"
```

Query the replica with any SQLite client, or start the worker with `--serve 5190` and
`curl localhost:5190`.

| Variable          | Default                 | Purpose                                   |
| ----------------- | ----------------------- | ----------------------------------------- |
| `RESTDIS_URL`     | `http://localhost:4042` | Restdis HTTP endpoint                     |
| `RESTDIS_API_KEY` | `sk_demo`               | Tenant API key, sent as a Bearer token    |
| `TURSO_PATH`      | `replica.db`            | Turso database file the worker writes to  |

The GIF is recorded by `demos/videos/record.mjs turso`; see that directory's README.
