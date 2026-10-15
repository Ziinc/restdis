#!/bin/sh
# Narrated walkthrough of the demo Supabase stack (demos/supabase/docker-compose.yml)
# for a screen recording. Brings the stack up, then drives Restdis through
# curl/psql, pausing between steps so a narrator can talk over each one.
#
# Usage: ./demo.sh            (start the stack, run the whole script)
#        ./demo.sh --no-up    (stack is already running, skip straight in)
set -eu

cd "$(dirname "$0")"

RESTDIS_URL="${RESTDIS_URL:-http://localhost:4041}"
API_KEY="${DEMO_API_KEY:-sk_demo}"
DIRECT_PG_URL="${DEMO_DIRECT_PG_URL:-postgres://postgres:postgres@localhost:5433/postgres}"
AUTH_URL="${DEMO_AUTH_URL:-http://localhost:9999}"
PGRST_URL="${DEMO_PGRST_URL:-http://localhost:3000}"
GRAFANA_URL="${DEMO_GRAFANA_URL:-http://localhost:3001}"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
step() { printf '\n\033[1;36m▶ %s\033[0m\n' "$1"; }
note() { printf '  \033[2m%s\033[0m\n' "$1"; }
pause() {
  if [ "${DEMO_AUTOPLAY:-0}" = "1" ]; then
    sleep "${1:-2}"
  else
    printf '\n  \033[2m(press enter to continue)\033[0m'
    read -r _
  fi
}

# The PostgREST query is URL-encoded as a whole, so its own `&` and `=` stay
# inside the `path` parameter instead of becoming parameters of /pgrst/query.
pgrst_query() {
  curl -sS -G -w '\n  status=%{http_code} time=%{time_total}s\n' \
    -H "authorization: Bearer $API_KEY" \
    --data-urlencode "path=$1" \
    "$RESTDIS_URL/pgrst/query"
}

psql_demo() {
  psql "$DIRECT_PG_URL" -v ON_ERROR_STOP=1 -c "$1"
}

if [ "${1:-}" != "--no-up" ]; then
  step "Bringing up the demo Supabase stack (Postgres + PostgREST + GoTrue + Restdis)"
  note "docker compose up -d --build"
  docker compose up -d --build
  note "waiting for Restdis to report healthy..."
  for _ in $(seq 1 30); do
    curl -fsS "$RESTDIS_URL/health" > /dev/null 2>&1 && break
    sleep 2
  done
  pause 3
fi

# seed.sql's tenant rows no-op at initdb time, before Restdis has created its
# control-plane tables. Re-apply it now that Restdis has migrated; it is
# idempotent.
docker compose exec -T -e PGOPTIONS="-c client_min_messages=warning" db \
  psql -U postgres -q -v ON_ERROR_STOP=1 \
  -f /docker-entrypoint-initdb.d/10-seed.sql > /dev/null

bold "=== Restdis + a real Supabase stack ==="
note "restdis:  $RESTDIS_URL"
note "postgrest: $PGRST_URL (Restdis's cache origin)"
note "auth:     $AUTH_URL (real GoTrue, wired for future Auth caching work)"
note "postgres: $DIRECT_PG_URL"
note "grafana:  $GRAFANA_URL (single-page dashboard, 1s refresh - open this now"
note "          in a browser pane on the left before continuing)"
if command -v open > /dev/null 2>&1; then
  open "$GRAFANA_URL/d/restdis-demo" 2> /dev/null || true
elif command -v xdg-open > /dev/null 2>&1; then
  xdg-open "$GRAFANA_URL/d/restdis-demo" 2> /dev/null || true
fi
pause

step "1. The origin: querying PostgREST directly, no cache involved"
note "curl $PGRST_URL/widgets?select=id,name&order=id"
curl -sS -w '\n  status=%{http_code} time=%{time_total}s\n' "$PGRST_URL/widgets?select=id,name&order=id"
pause

step "2. The same query through Restdis: first request is a cache MISS"
note "curl -G \"$RESTDIS_URL/pgrst/query\" --data-urlencode \"path=widgets?select=id,name&order=id\""
pgrst_query "widgets?select=id,name&order=id"
note "watch the response headers/logs: this one round-tripped to PostgREST"
pause

step "3. Repeat the exact same request: cache HIT, no trip to Postgres or PostgREST"
pgrst_query "widgets?select=id,name&order=id"
note "same data, and it came back straight from Restdis's in-memory cache"
pause

step "4. Prove it: update a row that's already in the cached result"
note "Restdis's reverse index maps (table, primary key) -> cache keys, populated"
note "from the pks actually present in a cached response. An insert has no such"
note "entry to look up, so inserts bust every cached list for the table instead"
note "(see PRD.md); updates/deletes bust only the lists that held the row's pk"
note "update widgets set name = 'updated widget' where id = 1"
psql_demo "update widgets set name = 'updated widget' where id = 1;" > /dev/null
note "Restdis is still serving the OLD cached result for a moment..."
pgrst_query "widgets?select=id,name&order=id"
pause

step "5. Restdis's WAL tailer sees the write and busts the cache automatically"
note "polling the same endpoint until the updated name shows up..."
for _ in $(seq 1 15); do
  body="$(curl -sS -H "authorization: Bearer $API_KEY" \
    "$RESTDIS_URL/pgrst/query?path=widgets%3Fselect=id,name%26order=id")"
  case "$body" in
    *"updated widget"*) break ;;
  esac
  sleep 1
done
pgrst_query "widgets?select=id,name&order=id"
note "no manual cache invalidation, no TTL wait: the WAL event drove the bust"
pause

step "6. The same thing from real application code: a supabase-js wrapper"
note "client/restdis-supabase.mjs wraps @supabase/supabase-js; select(cols, { cache: '30s' })"
note "reroutes through Restdis instead of the real client - see client/demo.mjs"
if [ ! -d client/node_modules ]; then
  note "installing client dependencies (first run only)..."
  (cd client && npm install --silent)
fi
(cd client && node demo.mjs)
pause

step "7. GoTrue is wired into the same stack, ready for the Auth caching phase"
note "curl $AUTH_URL/health"
curl -sS "$AUTH_URL/health"
echo
note "(SUPABASE_INTEGRATION_PRD.md: Auth caching is planned, not yet proxied by Restdis)"
pause

step "8. Load test: many tenants, many requests, high speed"
note "load-test.mjs seeds ${LOAD_TENANTS:-10} tenants sharing the widgets table, then"
note "fires ${LOAD_CONCURRENCY:-50} concurrent workers against them for ${LOAD_DURATION_S:-15}s"
note "watch the Grafana dashboard: this is the moment to point at it live"
RESTDIS_URL="$RESTDIS_URL" DEMO_DIRECT_PG_URL="$DIRECT_PG_URL" node load-test.mjs
pause

step "Done. Tearing down is optional:"
note "cd demos/supabase && docker compose down -v"
bold "=== end of demo ==="
