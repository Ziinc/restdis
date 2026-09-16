# ReverseIndex.add/4 fan-out benchmark, driven through Restdis.Cache.put/4.
#
# `Cache.put/4` calls `index_value/4` (`apps/restdis/lib/restdis/cache.ex`),
# which casts one `ReverseIndex.add/4` message *and* does two `:ets.insert/2`
# calls into `:bag` tables *per primary key* in the cached value
# (`apps/restdis/lib/restdis/cache/reverse_index.ex`). A cached response of
# 1,000 rows means 1,000 casts for one `put`. This measures `Cache.put/4`
# cost as a function of row count, isolating the reverse-index fan-out from
# ordinary write cost (a `:raw` key with no rows indexes nothing).
#
# Run with:
#
#     mix run apps/restdis/bench/reverse_index_add_bench.exs
#
# This is a standalone Benchee script (not an ExUnit test) and is not part
# of `mix test`.

Code.require_file("support/cache_bench_helper.exs", __DIR__)

alias Restdis.Bench.CacheHelper, as: H
alias Restdis.Cache
alias Restdis.Cache.Key

H.setup_app(Path.join(System.tmp_dir!(), "restdis_bench_reverse_index_add"))

row_counts = [1, 10, 100, 1_000]

jobs =
  Map.new(row_counts, fn count ->
    tenant_id = H.fresh_tenant("ridx#{count}_")
    rows = H.rows(count, 100)

    {"put (#{count} indexed rows)",
     fn ->
       key = Key.build(:table, "products", %{"i" => System.unique_integer([:positive])})
       Cache.put(tenant_id, key, rows)
     end}
  end)

no_index_tenant = H.fresh_tenant("ridx_none")

jobs =
  Map.put(jobs, "put (0 indexed rows, scalar value)", fn ->
    # A scalar value has no primary key to extract, so `index_value/4` walks
    # straight to `extract_pks/2`'s catch-all clause and indexes nothing.
    key = Key.build(:table, "counters", %{"i" => System.unique_integer([:positive])})
    Cache.put(no_index_tenant, key, "plain value")
  end)

Benchee.run(
  jobs,
  time: 2,
  warmup: 1,
  memory_time: 0.5,
  print: [configuration: false],
  title: "Restdis.Cache.put/4 reverse-index fan-out by row count"
)
