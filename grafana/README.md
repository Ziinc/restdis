# Restdis Grafana dashboard

`restdis-dashboard.json` is a Grafana dashboard covering the telemetry
restdis already emits: cache rewarm/persist activity, cluster
forward/fallback/rebalance/migration, replication lag, reverse-index
hit/miss, WAL tailer throughput/lag, singleton ownership, backpressure,
invalidation latency, and BEAM VM memory/run-queue metrics.

## Assumed exporter and naming convention

**This repo does not currently run PromEx or any dedicated Grafana-oriented
exporter.** The only metrics exporter wired up is
[`telemetry_metrics_prometheus_core`](https://hex.pm/packages/telemetry_metrics_prometheus_core)
(see `apps/restdis_server/mix.exs`, `apps/restdis_server/lib/restdis_server/application.ex`,
and the `/metrics` route in `apps/restdis_server/lib/restdis_server/http/endpoint.ex`),
configured with the metric definitions in
`apps/restdis_server/lib/restdis_server/metrics.ex`.

This dashboard's panel queries assume that exporter's naming convention:
`Telemetry.Metrics` names such as `restdis_buster.wal.received.bytes` are
rendered by the Prometheus text exposition format with dots replaced by
underscores and the metric-type suffix appended (`_count`, `_bucket`,
`_bytes`, etc. as appropriate for counters/sums/distributions/last_values).
For example:

- `restdis_server.rewarm.cold_read.count` (counter) -> `restdis_server_rewarm_cold_read_count`
- `restdis.replication.lag.lag_us` (distribution) -> `restdis_replication_lag_lag_us_bucket` (+ `_sum`/`_count`)
- `restdis_buster.tailer.lag.lag_us` (last_value) -> `restdis_buster_tailer_lag_lag_us`
- `vm.memory.total` (last_value) -> `vm_memory_total`

If the actual Prometheus scrape config or `telemetry_metrics_prometheus_core`
version in use renders names differently, adjust the panel queries (or the
Grafana datasource's metric relabeling) to match; the panels are organized so
each one maps 1:1 to a definition in `metrics.ex`, making it straightforward
to re-derive the correct query string per panel.

If/when the org standardizes on PromEx instead, this dashboard's panel
layout can be kept, but the metric names in each `targets[].expr` will need
to be updated to PromEx's naming convention (which differs from raw
`telemetry_metrics_prometheus_core` output).

## Importing

1. In Grafana, go to **Dashboards -> New -> Import**.
2. Upload `restdis-dashboard.json` or paste its contents.
3. When prompted, select the Prometheus datasource that scrapes restdis's
   `/metrics` endpoint (the dashboard exposes this as the `datasource`
   template variable).
4. The `tenant_id` template variable is populated from the `tenant_id` label
   on `restdis_persist_count_count`; adjust the query if you rename or drop
   that series.

## Scrape config assumption

The dashboard assumes Prometheus (or a compatible scraper, e.g. Grafana
Agent/Alloy) is configured to scrape `restdis_server`'s `/metrics` HTTP
endpoint on a normal interval (e.g. 15s). No such scrape config exists in
this repo yet (no `prometheus.yml` / VictoriaMetrics scrape config found
under `config/` or `deploy/`); this is a gap to fill alongside deploying
this dashboard.
