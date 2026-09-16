#!/bin/sh
# RESP-protocol walkthrough against the demo Supabase stack
# (demos/docker-compose.yml). Complements scripts/demo.sh, which drives
# Restdis's HTTP endpoint; this one drives the Redis wire protocol directly
# with redis-cli, covering the RESP command set, AUTH enforcement,
# PGRST.POLICY, and PERSIST that the HTTP walkthrough doesn't exercise.
#
# Usage: ./resp-demo.sh            (start the stack, run the whole script)
#        ./resp-demo.sh --no-up    (stack is already running, skip straight in)
set -eu

cd "$(dirname "$0")/.."

RESP_HOST="${DEMO_RESP_HOST:-localhost}"
RESP_PORT="${DEMO_RESP_PORT:-6381}"
API_KEY="${DEMO_API_KEY:-sk_demo}"
RESTDIS_URL="${RESTDIS_URL:-http://localhost:4041}"

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

rcli() {
  redis-cli -h "$RESP_HOST" -p "$RESP_PORT" "$@"
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

bold "=== Restdis's Redis wire protocol (RESP), against a real Supabase stack ==="
note "redis-cli -h $RESP_HOST -p $RESP_PORT"
pause

step "1. Unauthenticated connections can only PING and AUTH"
note "redis-cli ... GET some-key   (no AUTH yet)"
rcli GET some-key
note "NOAUTH, as expected - every other command is rejected until AUTH succeeds"
pause

step "2. AUTH with the tenant's Supabase API key"
note "redis-cli ... AUTH $API_KEY"
rcli AUTH "$API_KEY"
pause

step "3. Plain Redis commands work once authenticated: SET, GET, TTL, EXISTS"
note "SET, GET, and TTL are ordinary per-tenant cache entries, not PostgREST-backed"
rcli -a "$API_KEY" --no-auth-warning SET demo:counter 1
rcli -a "$API_KEY" --no-auth-warning GET demo:counter
rcli -a "$API_KEY" --no-auth-warning EXPIRE demo:counter 120
rcli -a "$API_KEY" --no-auth-warning TTL demo:counter
pause

step "4. PGRST.QUERY: fetch-and-cache a PostgREST query over RESP, not HTTP"
note "PGRST.QUERY widgets?select=id,name TTL 60 REWARM 5"
key="$(rcli -a "$API_KEY" --no-auth-warning PGRST.QUERY 'widgets?select=id,name' TTL 60 REWARM 5)"
note "canonical cache key: $key"
pause

step "5. PGRST.POLICY: flip that entry to PERSIST without re-fetching it"
note "PGRST.POLICY $key PERSIST"
rcli -a "$API_KEY" --no-auth-warning PGRST.POLICY "$key" PERSIST
note "persisted entries survive the cache's normal rewarm-driven eviction and"
note "write through to disk - see PRD.md's Rewarm and persistence section"
pause

step "6. PERSIST: the plain Redis command, capped at the tenant's max TTL"
note "PERSIST demo:counter"
rcli -a "$API_KEY" --no-auth-warning PERSIST demo:counter
note "returns 1 (applied) - restdis caps PERSIST at max_ttl_s rather than making"
note "the key immortal, since every entry is still subject to disk cache eviction"
pause

step "7. Rewarm: re-read the PGRST.QUERY entry before its 5s rewarm interval fires"
note "watching the WAL/rewarm metrics (see Grafana, if scripts/demo.sh is also up)"
for _ in 1 2 3; do
  rcli -a "$API_KEY" --no-auth-warning GET "$key" > /dev/null
  sleep 2
done
note "each read re-armed the rewarm timer; restdis re-queries PostgREST in the"
note "background on the interval as long as reads keep arriving"
pause

step "Done. Tearing down is optional:"
note "cd demos && docker compose down -v"
bold "=== end of RESP demo ==="
