# QueryCache.put/4 benchmark: write cost under and at the ETS memory cap.
#
# Every write calls `evict_over_cap/2`, which is cheap (`:ets.info/2`) below
# the cap, but on overflow calls `oldest_entry/1` — an `:ets.foldl/3` over
# the *entire* table — once per evicted entry, recursively
# (`apps/restdis/lib/restdis/cache/query_cache.ex`). That makes a single
# `put` that pushes the table over cap cost O(table size), and a `put` that
# evicts several entries cost O(table size * evicted count). This benchmark
# measures `put` throughput below cap at a few table sizes, then measures it
# again with the cap pinned so every `put` forces at least one eviction scan.
#
# Run with:
#
#     mix run apps/restdis/bench/query_cache_put_eviction_bench.exs
#
# This is a standalone Benchee script (not an ExUnit test) and is not part
# of `mix test`.

Code.require_file("support/cache_bench_helper.exs", __DIR__)

alias Restdis.Bench.CacheHelper, as: H
alias Restdis.Cache.Key
alias Restdis.Cache.QueryCache

H.setup_app(Path.join(System.tmp_dir!(), "restdis_bench_query_cache_put"))

value = H.rows(20)
table_sizes = [1_000, 10_000, 50_000]

Enum.each(table_sizes, fn size ->
  tenant_id = H.fresh_tenant("qcput")

  Enum.each(1..size, fn i ->
    QueryCache.put(tenant_id, Key.build(:table, "seed", %{"i" => i}), value)
  end)

  Benchee.run(
    %{
      "put (under cap, table_size=#{size})" => fn ->
        key = Key.build(:table, "bench", %{"i" => System.unique_integer([:positive])})
        QueryCache.put(tenant_id, key, value)
      end
    },
    time: 2,
    warmup: 1,
    memory_time: 0.5,
    print: [configuration: false],
    title: "QueryCache.put/4 below cap, table_size=#{size}"
  )
end)

# Pin the cap to the current memory footprint of a freshly seeded table so
# every subsequent `put` triggers exactly one eviction scan, isolating the
# cost of `oldest_entry/1` itself from ordinary insertion cost.
Enum.each(table_sizes, fn size ->
  tenant_id = H.fresh_tenant("qcevict")

  Enum.each(1..size, fn i ->
    QueryCache.put(tenant_id, Key.build(:table, "seed", %{"i" => i}), value)
  end)

  Application.put_env(:restdis, :ets_cap_bytes, QueryCache.memory_bytes(tenant_id))

  Benchee.run(
    %{
      "put (forces 1 eviction scan, table_size=#{size})" => fn ->
        key = Key.build(:table, "bench", %{"i" => System.unique_integer([:positive])})
        QueryCache.put(tenant_id, key, value)
      end
    },
    time: 2,
    warmup: 1,
    memory_time: 0.5,
    print: [configuration: false],
    title: "QueryCache.put/4 at cap (1 eviction/put), table_size=#{size}"
  )

  Application.delete_env(:restdis, :ets_cap_bytes)
end)
