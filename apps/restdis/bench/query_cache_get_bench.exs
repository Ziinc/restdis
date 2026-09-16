# QueryCache.get/2 benchmark: the L1 ETS read path.
#
# `Restdis.Cache.QueryCache.get/2` is the single most-called function in the
# cache: every `GET`/`MGET`/`EXISTS`/`TTL`/`Cache.get` probe starts here. A
# hit is not a pure read — it also writes an LRU timestamp back via
# `:ets.update_element/3` (`touch/2`) — so this measures how much that write
# costs under single-process and concurrent access, plus the miss and
# expired-hit arms.
#
# Run with:
#
#     mix run apps/restdis/bench/query_cache_get_bench.exs
#
# This is a standalone Benchee script (not an ExUnit test) and is not part
# of `mix test`.

Code.require_file("support/cache_bench_helper.exs", __DIR__)

alias Restdis.Bench.CacheHelper, as: H
alias Restdis.Cache.Key
alias Restdis.Cache.QueryCache

H.setup_app(Path.join(System.tmp_dir!(), "restdis_bench_query_cache_get"))

tenant_id = H.fresh_tenant("qcget")

hit_key = Key.build(:table, "products", %{"select" => "*"})
QueryCache.put(tenant_id, hit_key, H.rows(50))

expiring_value = H.rows(50)
expiring_key = Key.build(:table, "expiring", %{})

miss_key = Key.build(:table, "does_not_exist", %{})

concurrency_levels = [1, 8, 64]

Enum.each(concurrency_levels, fn n ->
  Benchee.run(
    %{
      "get (hit)" => fn -> QueryCache.get(tenant_id, hit_key) end,
      "get (miss)" => fn -> QueryCache.get(tenant_id, miss_key) end,
      # The expired-entry read arm deletes the entry as a side effect, so
      # each iteration re-arms it with an already-expired `put` first. This
      # measures the combined re-arm + expired-read cost, not the read alone.
      "put (expired) + get (expired hit)" => fn ->
        QueryCache.put(tenant_id, expiring_key, expiring_value, ttl_ms: -1)
        QueryCache.get(tenant_id, expiring_key)
      end
    },
    time: 2,
    warmup: 1,
    memory_time: 0.5,
    parallel: n,
    print: [configuration: false],
    title: "QueryCache.get/2 at parallel=#{n}"
  )
end)
