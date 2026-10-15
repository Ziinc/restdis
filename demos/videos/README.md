# Recorded demos

Source for the three GIFs in [`docs/demos/`](../../docs/demos). Each one runs a
client against Restdis on the left, with a console panel under the browser apps that logs every
request, its `sc-cache` header, and its response time. On the right are the live Restdis request log and the
live Postgres statement log (`log_statement=all`), so you can see which reads reach the
database and which Restdis answers itself.

| Demo | Client | What it shows |
| --- | --- | --- |
| `query` | supabase-js inside TanStack Query's `useQuery` | First fetch is a MISS, repeat fetches are HITs that never reach Postgres, and a write elsewhere evicts the entry through the WAL. |
| `db` | Two TanStack DB clients with `@tanstack/electric-db-collection` | Each client snapshots the shape, then polls Restdis live. Inserts, updates, a bulk insert and a delete reach both clients; each new or changed row costs one primary-key read. |
| `redis` | ioredis, default settings | `PGRST.QUERY` and `GET` over RESP, WAL eviction after a write, and `QUIT`. |

## Recording

Needs Docker, Node 22, and ffmpeg. The ioredis demo uses its default `HELLO 3` handshake and
`QUIT`, so the Restdis image must include #90 and #91.

```sh
cd demos/videos
npm ci
npm run build                      # bundle the two browser apps

docker compose up -d --build       # Postgres + PostgREST + Restdis
docker compose exec -T db psql -U postgres -f - < tenant.sql

npm run stage &                    # split-screen page on http://localhost:5180
npm run record                     # or: node record.mjs query db redis
```

`record.mjs` recreates the Restdis container before each recording, so every recording starts
from a cold cache. To build the image yourself first, run `docker build -t restdis:demo ../..`,
or set `RESTDIS_IMAGE` to an existing image.

To look around without recording, open `http://localhost:5180/?demo=query` (or `db`,
`redis`) and use the app yourself.

## Ports

| Service | Port (host) |
| --- | --- |
| restdis | 4042 (HTTP), 6382 (RESP) |
| db | 5434 |
| rest | 3002 |
| stage | 5180 |

## Files

- `docker-compose.yml`, `seed.sql`, `tenant.sql` - the stack and its data. `products` is in
  TTL mode, `todos` in replication mode.
- `app/query.jsx`, `app/db.jsx` - the two browser apps.
- `app/restdis-fetch.js` - the supabase-js fetch adapter: reads go to Restdis's `/pgrst/query`,
  everything else to PostgREST.
- `app/console.js` - the in-page console that logs `fetch()` and `console.log`.
- `redis-client.mjs` - the ioredis script.
- `stage.mjs`, `app/stage.html` - the split-screen page and the log streams behind it.
- `record.mjs` - drives each demo with Playwright and writes a GIF: 960 px wide, 4 fps,
  32 colours, then gifsicle's lossy pass, so each stays under 3 MB.
