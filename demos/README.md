# Demos

Three self-contained demo areas, one per category of functionality. Each has
its own README, and (except `electric`, which reuses the root dev stack) its
own `docker-compose.yml` - `cd` into one and follow its README without
needing the others running.

- **[`redis/`](redis/README.md)** - the Redis wire protocol (RESP): AUTH,
  plain Redis commands, `PGRST.QUERY`/`PGRST.POLICY` over RESP, `PERSIST`,
  rewarm. Lightweight stack (Postgres + PostgREST + Restdis, no GoTrue).
- **[`electric/`](electric/README.md)** - the Electric-SQL-compatible shape
  API: the conformance suite that runs the real `@electric-sql/client`
  against Restdis.
- **[`supabase/`](supabase/README.md)** - the full Supabase-integration demo:
  Restdis fronting real PostgREST + GoTrue + Postgres, HTTP cache walkthrough,
  WAL-driven invalidation, a `supabase-js` wrapper, a multi-tenant load test,
  and Grafana/Prometheus dashboards.
