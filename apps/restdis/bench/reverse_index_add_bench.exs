# ReverseIndex.add benchmark
#
# `add/4` used to be a GenServer.cast: a writer's `add` and the WAL
# worker's `purge_row`/`invalidate_by_row` are sent from different
# processes, so nothing guaranteed the cast was applied before a purge
# arrived and ran, letting a purge slip in ahead of the add it should
# have invalidated. `add` is now a GenServer.call so the index write is
# visible to the reverse index process before the caller (and thus any
# subsequent purge it triggers) proceeds.
#
# This measures the throughput of `add` under the current (call-based)
# implementation, both from a single caller process and from many
# concurrent callers, so a reviewer can see the cost of the
# synchronization the fix relies on.
#
# Run with:
#
#     mix run apps/restdis/bench/reverse_index_add_bench.exs

{:ok, _} = Application.ensure_all_started(:restdis)

alias Restdis.Cache.Key
alias Restdis.Cache.ReverseIndex
alias Restdis.Cache.TenantSupervisor

defmodule Restdis.Bench.ReverseIndexAdd do
  @moduledoc false

  def new_tenant do
    tenant_id = "bench_ri_#{System.unique_integer([:positive])}"
    TenantSupervisor.ensure_started(tenant_id)
    tenant_id
  end

  def concurrent_adds(tenant_id, key, concurrency, per_task) do
    1..concurrency
    |> Enum.map(fn t ->
      Task.async(fn ->
        Enum.each(1..per_task, fn i -> ReverseIndex.add(tenant_id, "bench", {t, i}, key) end)
      end)
    end)
    |> Task.await_many(:infinity)
  end
end

alias Restdis.Bench.ReverseIndexAdd, as: B

key = Key.build(:table, "bench", %{})

tenant_single = B.new_tenant()
tenant_concurrent = B.new_tenant()

counter = :counters.new(1, [])

Benchee.run(
  %{
    "add (single caller)" => fn ->
      i = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)
      ReverseIndex.add(tenant_single, "bench", i, key)
    end,
    "add + purge_row round trip" => fn ->
      i = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)
      ReverseIndex.add(tenant_single, "bench", i, key)
      ReverseIndex.purge_row(tenant_single, "bench", i)
    end
  },
  time: 2,
  warmup: 1,
  memory_time: 0,
  print: [configuration: false],
  title: "single-caller add throughput (GenServer.call)"
)

Benchee.run(
  %{
    "20 concurrent callers x 50 adds each" => fn ->
      B.concurrent_adds(tenant_concurrent, key, 20, 50)
    end
  },
  time: 2,
  warmup: 1,
  memory_time: 0,
  print: [configuration: false],
  title: "concurrent add throughput (GenServer.call)"
)
