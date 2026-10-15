# Recorded demos

Source for the three videos in [`docs/demos/`](../../docs/demos). Each one runs a stock
client against Restdis on the left. On the right are the live Restdis request log and the
live Postgres statement log (`log_statement=all`), so you can see which reads reach the
database and which Restdis answers itself.

| Video | Client | What it shows |
| --- | --- | --- |
| `query` | TanStack Query (`useQuery`) over HTTP | First fetch is a MISS, repeat fetches are HITs that never reach Postgres, and a write elsewhere evicts the entry through the WAL. |
| `db` | TanStack DB with `@tanstack/electric-db-collection` | One snapshot, then a live long-poll. Each write reaches the browser after a single primary-key read. |
| `redis` | ioredis | `PGRST.QUERY` and `GET` over RESP, with WAL eviction after a write. |

## Recording

Needs Docker, Node 22, and ffmpeg.

```sh
cd demos/videos
npm ci
npm run build                      # bundle the two browser apps

docker compose up -d --build       # Postgres + PostgREST + Restdis
docker compose exec -T db psql -U postgres -f - < tenant.sql

npm run stage &                    # split-screen page on http://localhost:5180
npm run record                     # or: node record.mjs query db redis
```

`record.mjs` recreates the Restdis container before each video, so every recording starts
from a cold cache. To build the image yourself first, run `docker build -t restdis:demo ../..`,
or set `RESTDIS_IMAGE` to an existing image.

To look around without recording, open `http://localhost:5180/?demo=query` (or `db`,
`redis`) and use the app yourself.

## Ports

| Service | Port (host) |
| --- | --- |
| restdis | 4042 (HTTP), 6382 (RESP) |
| db | 5434 |
| rest | 3001 |
| stage | 5180 |

## Files

- `docker-compose.yml`, `seed.sql`, `tenant.sql` - the stack and its data. `products` is in
  TTL mode, `todos` in replication mode.
- `app/query.jsx`, `app/db.jsx` - the two browser apps. The only Restdis-specific code in
  each is the URL.
- `redis-client.mjs` - the ioredis script.
- `stage.mjs`, `app/stage.html` - the split-screen page and the log streams behind it.
- `record.mjs` - drives each demo with Playwright and writes MP4 and GIF.
