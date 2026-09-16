# TenantSupervisor.ensure_started/1 benchmark: the fixed tax on every cache op.
#
# `Restdis.Cache.get/put/delete/peek` all call `ensure_started/1`
# unconditionally, on every invocation, even for a tenant that has been
# running for hours. By design it never short-circuits on a `TenantRegistry`
# lookup first — it always round-trips through
# `DynamicSupervisor.start_child/2`, a `GenServer.call` to one supervisor
# process shared by every tenant on the node
# (`apps/restdis/lib/restdis/cache/tenant_supervisor.ex`; see its moduledoc
# for the race that trade-off avoids). This measures that fixed per-op tax,
# and whether the shared supervisor process becomes a contention point as
# concurrent callers (across many different, already-started tenants)
# increase.
#
# Run with:
#
#     mix run apps/restdis/bench/tenant_supervisor_ensure_started_bench.exs
#
# This is a standalone Benchee script (not an ExUnit test) and is not part
# of `mix test`.

Code.require_file("support/cache_bench_helper.exs", __DIR__)

alias Restdis.Bench.CacheHelper, as: H
alias Restdis.Cache.TenantSupervisor

H.setup_app(Path.join(System.tmp_dir!(), "restdis_bench_tenant_supervisor"))

already_started_tenant = H.fresh_tenant("tsup_single")

# A pool of distinct, already-started tenants so the concurrent benchmark
# measures contention on the shared `TenantSupervisor` process itself, not
# repeated no-op calls for a single tenant.
pool_size = 256
tenant_pool = Enum.map(1..pool_size, fn _ -> H.fresh_tenant("tsup_pool") end)

concurrency_levels = [1, 8, 64]

Enum.each(concurrency_levels, fn n ->
  Benchee.run(
    %{
      "ensure_started (already-started tenant)" => fn ->
        TenantSupervisor.ensure_started(already_started_tenant)
      end,
      "ensure_started (random already-started tenant from pool of #{pool_size})" => fn ->
        TenantSupervisor.ensure_started(Enum.random(tenant_pool))
      end
    },
    time: 2,
    warmup: 1,
    memory_time: 0.5,
    parallel: n,
    print: [configuration: false],
    title: "TenantSupervisor.ensure_started/1 at parallel=#{n}"
  )
end)
