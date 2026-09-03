defmodule RestdisServer.Metrics do
  @moduledoc """
  Telemetry.Metrics definitions exported via the `/metrics` Prometheus endpoint.
  """

  import Telemetry.Metrics

  @doc """
  Returns the list of `Telemetry.Metrics` definitions scraped by
  `TelemetryMetricsPrometheus.Core`.
  """
  @spec definitions() :: [Telemetry.Metrics.t()]
  def definitions do
    [
      # HTTP / RESP rewarm
      counter("restdis_server.rewarm.cold_read.count", tags: [:tenant_id]),
      distribution("restdis_server.rewarm.refetch.duration_us",
        tags: [:tenant_id],
        unit: :microsecond,
        reporter_options: [buckets: [1_000, 5_000, 10_000, 50_000, 100_000, 500_000, 1_000_000]]
      ),
      counter("restdis_server.rewarm.error.count", tags: [:tenant_id, :reason]),
      counter("restdis_server.rewarm.evicted.count", tags: [:tenant_id, :reason]),

      # Cache persistence
      counter("restdis.persist.cap_reached.count", tags: [:tenant_id]),
      last_value("restdis.persist.count.count", tags: [:tenant_id]),

      # Cache resource caps (ETS memory / CubDB disk)
      counter("restdis.cache.ets_evict.count", tags: [:tenant_id]),
      counter("restdis.cache.cubdb_evict.count", tags: [:tenant_id]),

      # Shape filters: how often the index answers, how many shapes each change tests against, and fan-out latency.
      distribution("restdis_electric.filter.lookup.candidates",
        tags: [:tenant_id, :table],
        reporter_options: [buckets: [1, 2, 5, 10, 25, 50, 100, 500, 1_000]]
      ),
      distribution("restdis_electric.filter.lookup.indexed",
        tags: [:tenant_id, :table],
        reporter_options: [buckets: [1, 2, 5, 10, 25, 50, 100, 500, 1_000]]
      ),
      distribution("restdis_electric.filter.lookup.unindexed",
        tags: [:tenant_id, :table],
        reporter_options: [buckets: [1, 2, 5, 10, 25, 50, 100, 500, 1_000]]
      ),
      counter("restdis_electric.wal.ingest.appended", tags: [:tenant_id, :table, :operation]),
      distribution("restdis_electric.wal.ingest.tested",
        tags: [:tenant_id, :table],
        reporter_options: [buckets: [1, 2, 5, 10, 25, 50, 100, 500, 1_000]]
      ),
      distribution("restdis_electric.wal.ingest.duration",
        tags: [:tenant_id, :table],
        unit: {:native, :microsecond},
        reporter_options: [buckets: [100, 500, 1_000, 5_000, 10_000, 50_000, 100_000]]
      ),
      distribution("restdis_electric.where.parse.duration",
        tags: [:result],
        unit: {:native, :microsecond},
        reporter_options: [buckets: [100, 500, 1_000, 5_000, 10_000, 50_000]]
      ),

      # Cluster distribution
      counter("restdis.cluster.forward.count", tags: [:tenant_id, :owner, :op]),
      counter("restdis.cluster.unreachable.count", tags: [:tenant_id, :owner, :op]),
      counter("restdis.cluster.rebalance.count", tags: [:change, :node]),
      last_value("restdis.cluster.rebalance.nodes", tags: [:change]),
      counter("restdis.cluster.migrated.count", tags: [:tenant_id, :owner]),
      counter("restdis_server.cluster.fallback.count", tags: [:tenant_id]),
      distribution("restdis.replication.lag.lag_us",
        tags: [:tenant_id],
        unit: :microsecond,
        reporter_options: [buckets: [1_000, 10_000, 50_000, 100_000, 500_000, 1_000_000]]
      ),

      # Reverse index
      counter("restdis_buster.reverse_index.miss.count", tags: [:tenant_id, :table]),
      sum("restdis_buster.reverse_index.hit.keys", tags: [:tenant_id, :table]),

      # WAL tailer
      sum("restdis_buster.wal.received.bytes", unit: :byte),
      sum("restdis_buster.wal.received.count"),
      sum("restdis_buster.wal.decoded.count"),
      last_value("restdis_buster.tailer.lag.lag_us", unit: :microsecond),

      # Singleton election
      last_value("restdis_buster.singleton.owner.is_owner", tags: [:node]),

      # Backpressure / coalescing
      counter("restdis_buster.backpressure.triggered.count", tags: [:tenant_id, :table]),
      sum("restdis_buster.backpressure.flushed.coalesced_count",
        tags: [:tenant_id, :table]
      ),

      # Change events / invalidation
      counter("restdis_buster.event.processed.count", tags: [:op, :schema, :table]),
      distribution("restdis_buster.event.processed.duration_us",
        tags: [:op, :schema, :table],
        unit: :microsecond,
        reporter_options: [buckets: [100, 500, 1_000, 5_000, 10_000, 50_000, 100_000]]
      ),
      distribution("restdis_buster.invalidation.latency.duration_us",
        tags: [:tenant_id, :table, :op],
        unit: :microsecond,
        reporter_options: [buckets: [100, 500, 1_000, 5_000, 10_000, 50_000, 100_000]]
      ),

      # VM measurements
      last_value("vm.memory.total", unit: :byte),
      last_value("vm.total_run_queue_lengths.total")
    ]
  end

  @doc """
  Periodic measurements polled by `:telemetry_poller` on top of the
  ad-hoc `:telemetry.execute/3` calls made throughout the application.
  """
  @spec periodic_measurements() :: [:telemetry_poller.measurement()]
  def periodic_measurements do
    [
      {RestdisServer.Metrics, :dispatch_vm_metrics, []}
    ]
  end

  @doc false
  @spec dispatch_vm_metrics() :: :ok
  def dispatch_vm_metrics do
    :telemetry.execute([:vm, :memory], %{total: :erlang.memory(:total)}, %{})

    :telemetry.execute(
      [:vm, :total_run_queue_lengths],
      %{total: :erlang.statistics(:total_run_queue_lengths_all)},
      %{}
    )
  end
end
