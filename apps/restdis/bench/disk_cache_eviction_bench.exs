# DiskCache cap eviction benchmark: the `evict_over_cap/1` path.
#
# When a `put` pushes the tenant's FeoxDB store over its byte cap,
# `do_evict_over_cap/3` (`apps/restdis/lib/restdis/cache/disk_cache.ex`) takes
# the oldest non-persisted key off the in-memory `:gb_sets` eviction index,
# reads its size back from the store and deletes it, once per evicted key,
# inside the tenant's disk-cache GenServer. Every write for the tenant queues
# behind that work. This measures the `put`-that-forces-eviction cost as a
# function of store size, contrasted with an ordinary below-cap `put`.
#
# Run with:
#
#     mix run --no-start apps/restdis/bench/disk_cache_eviction_bench.exs
#
# This is a standalone Benchee script (not an ExUnit test) and is not part
# of `mix test`.

Code.require_file("support/cache_bench_helper.exs", __DIR__)

alias Restdis.Bench.CacheHelper, as: H
alias Restdis.Cache.DiskCache
alias Restdis.Cache.InstanceConfig
alias Restdis.Cache.Key

H.setup_app(Path.join(System.tmp_dir!(), "restdis_bench_disk_cache_eviction"))

name = H.name()
default_cap = InstanceConfig.fetch!(name).disk_cap_bytes
value = :crypto.strong_rand_bytes(256)
store_sizes = [1_000, 10_000, 50_000]

seed = fn tenant_id, size ->
  Enum.each(1..size, fn i ->
    DiskCache.put(tenant_id, Key.build(:table, "seed", %{"i" => i}), value, name: name)
  end)
end

Enum.each(store_sizes, fn size ->
  tenant_id = H.fresh_tenant("dcevict_below")
  seed.(tenant_id, size)

  Benchee.run(
    %{
      "put (below cap, store_size=#{size})" => fn ->
        key = Key.build(:table, "bench", %{"i" => System.unique_integer([:positive])})
        DiskCache.put(tenant_id, key, value, name: name)
      end
    },
    time: 2,
    warmup: 1,
    memory_time: 0.5,
    print: [configuration: false],
    title: "DiskCache.put/4 below cap, store_size=#{size}"
  )

  Restdis.Cache.flush_tenant(tenant_id)
end)

Enum.each(store_sizes, fn size ->
  tenant_id = H.fresh_tenant("dcevict_at")
  seed.(tenant_id, size)

  # Pin the cap to the current byte tally so every subsequent `put` evicts
  # exactly one entry to make room for itself.
  H.put_cap(:disk_cap_bytes, DiskCache.disk_size_bytes(name, tenant_id))

  Benchee.run(
    %{
      "put (forces 1 eviction, store_size=#{size})" => fn ->
        key = Key.build(:table, "bench", %{"i" => System.unique_integer([:positive])})
        DiskCache.put(tenant_id, key, value, name: name)
      end
    },
    time: 2,
    warmup: 1,
    memory_time: 0.5,
    print: [configuration: false],
    title: "DiskCache.put/4 at cap (1 eviction/put), store_size=#{size}"
  )

  H.put_cap(:disk_cap_bytes, default_cap)
  Restdis.Cache.flush_tenant(tenant_id)
end)
