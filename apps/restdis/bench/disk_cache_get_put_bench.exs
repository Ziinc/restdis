# DiskCache.get/3 and put/4 benchmark: direct reads vs. the per-tenant write path.
#
# `get/3` reads the tenant's FeoxDB store directly from the caller's process,
# using the store reference held in `TenantRegistry`, so concurrent readers do
# not queue behind each other. Every `put/4` is still a `GenServer.call`
# through one process per tenant (`apps/restdis/lib/restdis/cache/disk_cache.ex`)
# that re-reads the old entry to keep the byte tally and eviction index
# right, so that process is a throughput ceiling for writes regardless of how
# many callers try to use it concurrently. This measures call latency and
# throughput at a few value sizes, and how each degrades as concurrent
# callers increase.
#
# The disk cap is lowered to 128 MB so the 1 MB `put` runs evict in steady
# state rather than filling the scratch disk.
#
# Run with:
#
#     mix run --no-start apps/restdis/bench/disk_cache_get_put_bench.exs
#
# This is a standalone Benchee script (not an ExUnit test) and is not part
# of `mix test`.

Code.require_file("support/cache_bench_helper.exs", __DIR__)

alias Restdis.Bench.CacheHelper, as: H
alias Restdis.Cache.DiskCache
alias Restdis.Cache.Key

H.setup_app(
  Path.join(System.tmp_dir!(), "restdis_bench_disk_cache_get_put"),
  disk_cap_bytes: 128 * 1024 * 1024
)

name = H.name()
value_sizes = [1_024, 65_536, 1_048_576]
concurrency_levels = [1, 8, 64]

Enum.each(value_sizes, fn value_size ->
  tenant_id = H.fresh_tenant("dcgp")
  value = :crypto.strong_rand_bytes(value_size)
  get_key = Key.build(:table, "get_target", %{})
  DiskCache.put(tenant_id, get_key, value, name: name, persist: true)

  Enum.each(concurrency_levels, fn n ->
    Benchee.run(
      %{
        "get (hit)" => fn -> DiskCache.get(name, tenant_id, get_key) end,
        "put" => fn ->
          key = Key.build(:table, "put_target", %{"i" => System.unique_integer([:positive])})
          DiskCache.put(tenant_id, key, value, name: name)
        end
      },
      time: 2,
      warmup: 1,
      memory_time: 0.5,
      parallel: n,
      print: [configuration: false],
      title: "DiskCache value_size=#{value_size}B, parallel=#{n}"
    )
  end)

  Restdis.Cache.flush_tenant(tenant_id)
end)
