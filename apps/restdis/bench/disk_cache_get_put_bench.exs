# DiskCache.get/2 and put/4 benchmark: the per-tenant GenServer serialization point.
#
# Every disk-layer operation is a `GenServer.call` through one process per
# tenant (`apps/restdis/lib/restdis/cache/disk_cache.ex`), so that process is
# a hard throughput ceiling regardless of how many callers try to use it
# concurrently. `put` additionally re-reads the old entry via
# `CubDB.fetch/2` before writing (`entry_size/2`) and computes
# `:erlang.external_size/1` on the new one. This measures call latency and
# throughput at a few value sizes, and how throughput degrades as concurrent
# callers increase.
#
# Run with:
#
#     mix run apps/restdis/bench/disk_cache_get_put_bench.exs
#
# This is a standalone Benchee script (not an ExUnit test) and is not part
# of `mix test`.

Code.require_file("support/cache_bench_helper.exs", __DIR__)

alias Restdis.Bench.CacheHelper, as: H
alias Restdis.Cache.DiskCache
alias Restdis.Cache.Key

H.setup_app(Path.join(System.tmp_dir!(), "restdis_bench_disk_cache_get_put"))

value_sizes = [1_024, 65_536, 1_048_576]
concurrency_levels = [1, 8, 64]

Enum.each(value_sizes, fn value_size ->
  tenant_id = H.fresh_tenant("dcgp")
  value = :crypto.strong_rand_bytes(value_size)
  get_key = Key.build(:table, "get_target", %{})
  DiskCache.put(tenant_id, get_key, value)

  Enum.each(concurrency_levels, fn n ->
    Benchee.run(
      %{
        "get (hit)" => fn -> DiskCache.get(tenant_id, get_key) end,
        "put" => fn ->
          key = Key.build(:table, "put_target", %{"i" => System.unique_integer([:positive])})
          DiskCache.put(tenant_id, key, value)
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
end)
