# TenantSupervisor.ensure_started/2 benchmark: the fixed tax on every cache op.
#
# `Restdis.Cache.get/put/delete/peek` all call `ensure_started/2`
# unconditionally, on every invocation, even for a tenant that has been
# running for hours. For an already-running tenant it short-circuits on a
# lock-free `TenantRegistry` lookup of the tenant's `:reverse_index` process
# and never reaches the `DynamicSupervisor` shared by every tenant on the
# node (`apps/restdis/lib/restdis/cache/tenant_supervisor.ex`). This measures
# that fixed per-op tax, and whether it stays flat as concurrent callers
# (across many different, already-started tenants) increase.
#
# `tenant_ensure_started_bench.exs` times the same fast path by hand; this
# one adds Benchee statistics across parallelism levels. `tenant_churn_bench.exs`
# covers cold starts.
#
# Run with:
#
#     mix run --no-start apps/restdis/bench/tenant_supervisor_ensure_started_bench.exs
#
# This is a standalone Benchee script (not an ExUnit test) and is not part
# of `mix test`.

Code.require_file("support/cache_bench_helper.exs", __DIR__)

alias Restdis.Bench.CacheHelper, as: H
alias Restdis.Cache.TenantSupervisor

H.setup_app(Path.join(System.tmp_dir!(), "restdis_bench_tenant_supervisor"))

name = H.name()
already_started_tenant = H.fresh_tenant("tsup_single")

# A pool of distinct, already-started tenants so the concurrent benchmark
# measures lookups spread across the registry, not repeated calls for a
# single tenant.
pool_size = 256
tenant_pool = Enum.map(1..pool_size, fn _ -> H.fresh_tenant("tsup_pool") end)

concurrency_levels = [1, 8, 64]

Enum.each(concurrency_levels, fn n ->
  Benchee.run(
    %{
      "ensure_started (already-started tenant)" => fn ->
        TenantSupervisor.ensure_started(name, already_started_tenant)
      end,
      "ensure_started (random already-started tenant from pool of #{pool_size})" => fn ->
        TenantSupervisor.ensure_started(name, Enum.random(tenant_pool))
      end
    },
    time: 2,
    warmup: 1,
    memory_time: 0.5,
    parallel: n,
    print: [configuration: false],
    title: "TenantSupervisor.ensure_started/2 at parallel=#{n}"
  )
end)
