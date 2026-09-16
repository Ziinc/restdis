# DiskCache cap eviction benchmark: the `oldest_non_persist_key/1` scan.
#
# When a `put` pushes the tenant's CubDB store over its byte cap,
# `oldest_non_persist_key/1` (`apps/restdis/lib/restdis/cache/disk_cache.ex`)
# streams *every* entry in the store via `CubDB.select/1`, filters to
# non-persisted ones, and finds the minimum by insertion time — once per
# evicted key, recursively, inside the tenant's single disk-cache
# GenServer. That blocks every disk read and write for the tenant while it
# runs. This measures the `put`-that-forces-eviction cost as a function of
# store size, contrasted with an ordinary below-cap `put`.
#
# Run with:
#
#     mix run apps/restdis/bench/disk_cache_eviction_bench.exs
#
# This is a standalone Benchee script (not an ExUnit test) and is not part
# of `mix test`.

Code.require_file("support/cache_bench_helper.exs", __DIR__)

alias Restdis.Bench.CacheHelper, as: H
alias Restdis.Cache.DiskCache
alias Restdis.Cache.Key

H.setup_app(Path.join(System.tmp_dir!(), "restdis_bench_disk_cache_eviction"))

value = :crypto.strong_rand_bytes(256)
store_sizes = [1_000, 10_000, 50_000]

Enum.each(store_sizes, fn size ->
  tenant_id = H.fresh_tenant("dcevict_below")

  Enum.each(1..size, fn i ->
    DiskCache.put(tenant_id, Key.build(:table, "seed", %{"i" => i}), value)
  end)

  Benchee.run(
    %{
      "put (below cap, store_size=#{size})" => fn ->
        key = Key.build(:table, "bench", %{"i" => System.unique_integer([:positive])})
        DiskCache.put(tenant_id, key, value)
      end
    },
    time: 2,
    warmup: 1,
    memory_time: 0.5,
    print: [configuration: false],
    title: "DiskCache.put/4 below cap, store_size=#{size}"
  )
end)

# A smaller size ladder than the below-cap scenario: `oldest_non_persist_key/1`
# is a full `CubDB.select/1` scan done fresh on *every* forced eviction, and
# Benchee calls the benchmarked function many times per second — at 50,000
# entries that repeated O(n) scan is slow enough to blow past the disk
# cache's default 5s `GenServer.call` timeout and crash the whole run.
eviction_store_sizes = [200, 1_000, 5_000]

Enum.each(eviction_store_sizes, fn size ->
  tenant_id = H.fresh_tenant("dcevict_at")

  Enum.each(1..size, fn i ->
    DiskCache.put(tenant_id, Key.build(:table, "seed", %{"i" => i}), value)
  end)

  # Pin the cap to the current on-disk footprint so every subsequent `put`
  # triggers exactly one `oldest_non_persist_key/1` scan.
  Application.put_env(:restdis, :cubdb_cap_bytes, DiskCache.disk_size_bytes(tenant_id))

  Benchee.run(
    %{
      "put (forces 1 eviction scan, store_size=#{size})" => fn ->
        key = Key.build(:table, "bench", %{"i" => System.unique_integer([:positive])})
        DiskCache.put(tenant_id, key, value)
      end
    },
    time: 1,
    warmup: 0.5,
    memory_time: 0.5,
    print: [configuration: false],
    title: "DiskCache.put/4 at cap (1 eviction scan/put), store_size=#{size}"
  )

  Application.delete_env(:restdis, :cubdb_cap_bytes)
end)
