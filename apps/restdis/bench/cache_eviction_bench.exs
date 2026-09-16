# Cache eviction scaling benchmark
#
# `Restdis.Cache.QueryCache` and `Restdis.Cache.DiskCache` enforce a
# per-tenant byte cap by evicting the least-recently-used entry whenever a
# `put` pushes the tenant over its cap. Before the ordered-by-access index
# was added, finding that LRU entry required a full scan of the tenant's
# table (an `:ets.foldl` for `QueryCache`, a full `CubDB.select` for
# `DiskCache`) on *every* evicted key, making sustained eviction O(n) per
# put and O(n·k) overall for k evictions.
#
# This benchmark holds a tenant's cache at a fixed size N (just at its cap)
# and repeatedly performs a "cap-triggering put": each put inserts one new
# entry and evicts exactly one LRU entry to compensate, so the table size
# stays ~N throughout. It reports the average time per such put at several
# values of N. With the O(n) scan, that average grows with N; with the
# ordered index it stays flat.
#
# Run with:
#
#     mix run apps/restdis/bench/cache_eviction_bench.exs

alias Restdis.Cache.DiskCache
alias Restdis.Cache.Key
alias Restdis.Cache.QueryCache
alias Restdis.Cache.TenantSupervisor

Application.put_env(
  :restdis,
  :cache_data_dir,
  System.tmp_dir!() <> "/restdis_bench_eviction"
)

File.rm_rf!(System.tmp_dir!() <> "/restdis_bench_eviction")
{:ok, _pid} = Restdis.Cache.Supervisor.start_link([])

value = String.duplicate("x", 200)
volumes = [1_000, 5_000, 20_000]
puts_per_measurement = 200

report = fn label, value -> IO.puts("#{label}: #{value}") end

IO.puts("\n=== QueryCache: cost of a cap-triggering put at steady-state size N ===")

Enum.each(volumes, fn n ->
  tenant_id = "bench_qc_#{n}_#{System.unique_integer([:positive])}"
  TenantSupervisor.ensure_started(tenant_id)

  keys = for i <- 1..n, do: Key.build(:table, "t#{i}", %{"i" => i})
  Enum.each(keys, fn key -> QueryCache.put(tenant_id, key, value) end)

  mem = QueryCache.memory_bytes(tenant_id)
  # Cap sits right at the current footprint: every further put grows memory
  # past the cap and forces exactly one eviction before returning.
  Application.put_env(:restdis, :ets_cap_bytes, mem)

  extra_keys =
    for i <- (n + 1)..(n + puts_per_measurement),
        do: Key.build(:table, "t#{i}", %{"i" => i})

  {time_us, _} =
    :timer.tc(fn ->
      Enum.each(extra_keys, fn key -> QueryCache.put(tenant_id, key, value) end)
    end)

  Application.delete_env(:restdis, :ets_cap_bytes)
  Restdis.Cache.flush_tenant(tenant_id)

  avg_us = time_us / puts_per_measurement
  report.("N=#{n} avg time per cap-triggering put (us)", Float.round(avg_us, 2))
end)

IO.puts("\n=== DiskCache: cost of a cap-triggering put at steady-state size N ===")

Enum.each(volumes, fn n ->
  tenant_id = "bench_dc_#{n}_#{System.unique_integer([:positive])}"
  TenantSupervisor.ensure_started(tenant_id)

  keys = for i <- 1..n, do: Key.build(:table, "t#{i}", %{"i" => i})
  Enum.each(keys, fn key -> DiskCache.put(tenant_id, key, value) end)

  bytes = DiskCache.disk_size_bytes(tenant_id)
  Application.put_env(:restdis, :cubdb_cap_bytes, bytes)

  extra_keys =
    for i <- (n + 1)..(n + puts_per_measurement),
        do: Key.build(:table, "t#{i}", %{"i" => i})

  {time_us, _} =
    :timer.tc(fn ->
      Enum.each(extra_keys, fn key -> DiskCache.put(tenant_id, key, value) end)
    end)

  Application.delete_env(:restdis, :cubdb_cap_bytes)
  Restdis.Cache.flush_tenant(tenant_id)

  avg_us = time_us / puts_per_measurement
  report.("N=#{n} avg time per cap-triggering put (us)", Float.round(avg_us, 2))
end)
