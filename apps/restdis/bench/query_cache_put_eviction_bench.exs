# QueryCache.put/4 benchmark: write cost under and at the ETS memory cap.
#
# Every write calls `evict_over_cap/4`, which is cheap (`:ets.info/2`) below
# the cap. On overflow it pops the least-recently-used entry off the ordered
# index table with `:ets.first/1` and deletes it, once per evicted entry
# (`apps/restdis/lib/restdis/cache/query_cache.ex`). This benchmark measures
# `put` throughput below cap at a few table sizes, then again with the cap
# pinned so every `put` forces at least one eviction, to confirm eviction cost
# stays flat as the table grows.
#
# Run with:
#
#     mix run --no-start apps/restdis/bench/query_cache_put_eviction_bench.exs
#
# This is a standalone Benchee script (not an ExUnit test) and is not part
# of `mix test`.

Code.require_file("support/cache_bench_helper.exs", __DIR__)

alias Restdis.Bench.CacheHelper, as: H
alias Restdis.Cache.InstanceConfig
alias Restdis.Cache.Key
alias Restdis.Cache.QueryCache

H.setup_app(Path.join(System.tmp_dir!(), "restdis_bench_query_cache_put"))

name = H.name()
default_cap = InstanceConfig.fetch!(name).ets_cap_bytes
value = H.rows(20)
table_sizes = [1_000, 10_000, 50_000]

seed = fn tenant_id, size ->
  Enum.each(1..size, fn i ->
    QueryCache.put(tenant_id, Key.build(:table, "seed", %{"i" => i}), value, name: name)
  end)
end

Enum.each(table_sizes, fn size ->
  tenant_id = H.fresh_tenant("qcput")
  seed.(tenant_id, size)

  Benchee.run(
    %{
      "put (under cap, table_size=#{size})" => fn ->
        key = Key.build(:table, "bench", %{"i" => System.unique_integer([:positive])})
        QueryCache.put(tenant_id, key, value, name: name)
      end
    },
    time: 2,
    warmup: 1,
    memory_time: 0.5,
    print: [configuration: false],
    title: "QueryCache.put/4 below cap, table_size=#{size}"
  )

  Restdis.Cache.flush_tenant(tenant_id)
end)

# Pin the cap to the current memory footprint of a freshly seeded table so
# every subsequent `put` triggers an eviction, isolating eviction cost from
# ordinary insertion cost.
Enum.each(table_sizes, fn size ->
  tenant_id = H.fresh_tenant("qcevict")
  seed.(tenant_id, size)

  H.put_cap(:ets_cap_bytes, QueryCache.memory_bytes(name, tenant_id))

  Benchee.run(
    %{
      "put (forces eviction, table_size=#{size})" => fn ->
        key = Key.build(:table, "bench", %{"i" => System.unique_integer([:positive])})
        QueryCache.put(tenant_id, key, value, name: name)
      end
    },
    time: 2,
    warmup: 1,
    memory_time: 0.5,
    print: [configuration: false],
    title: "QueryCache.put/4 at cap (evicts on every put), table_size=#{size}"
  )

  H.put_cap(:ets_cap_bytes, default_cap)
  Restdis.Cache.flush_tenant(tenant_id)
end)
