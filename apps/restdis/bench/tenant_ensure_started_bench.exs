# TenantSupervisor.ensure_started/1 benchmark
#
# `Restdis.Cache.get/2`, `put/4`, `delete/3`, etc. all call `ensure_started/1`
# on every request. Before the fix this always went through
# `DynamicSupervisor.start_child/2`, i.e. a `GenServer.call` to the single
# `Restdis.Cache.TenantSupervisor` process shared by every tenant on the
# node — serialising all tenants' reads through one mailbox. The fix adds a
# `Registry.lookup/2` fast path (lock-free, no message passing to a shared
# process) that only falls through to `start_child/2` the first time a
# tenant is seen.
#
# This benchmark measures both the warm-tenant fast path itself and, more
# importantly, whether many tenants hitting `ensure_started/1` concurrently
# still serialise through the shared `DynamicSupervisor` once each tenant is
# already running.
#
# Run with:
#
#     mix run apps/restdis/bench/tenant_ensure_started_bench.exs

alias Restdis.Cache.TenantSupervisor

defmodule Restdis.Bench.EnsureStarted do
  @moduledoc false

  @doc "Old code path: unconditionally ask the DynamicSupervisor to start the child."
  def start_child_always(tenant_id) do
    data_dir = Application.fetch_env!(:restdis, :cache_data_dir)
    child_spec = {Restdis.Cache.Tenant, tenant_id: tenant_id, data_dir: data_dir}

    case DynamicSupervisor.start_child(TenantSupervisor, child_spec) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  @doc "Spawns `n` tenants and runs `per_tenant` warm-path calls concurrently across all of them."
  def concurrent_warm_calls(tenant_ids, per_tenant, fun) do
    tenant_ids
    |> Enum.map(fn tenant_id ->
      Task.async(fn ->
        Enum.each(1..per_tenant, fn _ -> fun.(tenant_id) end)
      end)
    end)
    |> Task.await_many(:infinity)
  end
end

alias Restdis.Bench.EnsureStarted, as: B

tenant_count = 200
tenant_ids = Enum.map(1..tenant_count, fn i -> "bench_ensure_started_#{i}" end)

Enum.each(tenant_ids, &TenantSupervisor.ensure_started/1)

IO.puts("\n=== warm single-process throughput ===")

Benchee.run(
  %{
    "ensure_started/1 (Registry fast path)" => fn ->
      TenantSupervisor.ensure_started(Enum.random(tenant_ids))
    end,
    "DynamicSupervisor.start_child/2 (old path, always)" => fn ->
      B.start_child_always(Enum.random(tenant_ids))
    end
  },
  time: 2,
  warmup: 1,
  memory_time: 0,
  print: [configuration: false],
  title: "warm tenant, single caller"
)

IO.puts("\n=== #{tenant_count} tenants x 200 calls each, run concurrently ===")

{fast_us, _} =
  :timer.tc(fn ->
    B.concurrent_warm_calls(tenant_ids, 200, &TenantSupervisor.ensure_started/1)
  end)

{old_us, _} =
  :timer.tc(fn ->
    B.concurrent_warm_calls(tenant_ids, 200, &B.start_child_always/1)
  end)

IO.puts("Registry fast path total wall time (us): #{fast_us}")
IO.puts("Old start_child-always path total wall time (us): #{old_us}")
IO.puts("speedup: #{Float.round(old_us / fast_us, 2)}x")

Enum.each(tenant_ids, &Restdis.Cache.flush_tenant/1)
