# Restdis.Cache.get/2 benchmark: the composed L1 -> disk -> origin ladder.
#
# `Cache.get/2` (`apps/restdis/lib/restdis/cache.ex`) is what every read
# command actually calls. Each call pays `TenantId.cast!/1` (a regex) and
# `TenantSupervisor.ensure_started/1` (a call to the global dynamic
# supervisor) before even reaching the cache layers. This measures the three
# distinct arms callers hit in practice:
#
#   * L1 hit        — QueryCache satisfies it directly
#   * L1 miss, disk hit — falls through to DiskCache and promotes into L1
#   * full miss     — falls through to the (stub) origin
#
# Run with:
#
#     mix run apps/restdis/bench/cache_get_ladder_bench.exs
#
# This is a standalone Benchee script (not an ExUnit test) and is not part
# of `mix test`.

Code.require_file("support/cache_bench_helper.exs", __DIR__)

alias Restdis.Bench.CacheHelper, as: H
alias Restdis.Cache
alias Restdis.Cache.DiskCache
alias Restdis.Cache.Key
alias Restdis.Cache.QueryCache

H.setup_app(Path.join(System.tmp_dir!(), "restdis_bench_cache_get_ladder"))

tenant_id = H.fresh_tenant("ladder")
value = H.rows(50)

l1_hit_key = Key.build(:table, "l1_hit", %{})
Cache.put(tenant_id, l1_hit_key, value)

# Present on disk but not (yet, or any more) promoted into the L1 ETS table.
disk_hit_key = Key.build(:table, "disk_hit", %{})
DiskCache.put(tenant_id, disk_hit_key, value)

full_miss_key = Key.build(:table, "full_miss", %{})

Benchee.run(
  %{
    "get (L1 hit)" => fn -> Cache.get(tenant_id, l1_hit_key) end,
    "get (L1 miss, disk hit + promote)" => fn ->
      # Evict from L1 every iteration so this arm keeps exercising the disk
      # fallback + promotion path rather than degrading into an L1 hit after
      # the first call.
      QueryCache.delete(tenant_id, disk_hit_key)
      Cache.get(tenant_id, disk_hit_key)
    end,
    "get (full miss, origin fetch)" => fn -> Cache.get(tenant_id, full_miss_key) end
  },
  time: 2,
  warmup: 1,
  memory_time: 0.5,
  print: [configuration: false],
  title: "Restdis.Cache.get/2 read ladder"
)
