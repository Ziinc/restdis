# Disk cache concurrent-read benchmark
#
# Restdis.Cache.DiskCache.get/2 and peek_meta/2 used to route through a
# GenServer.call to the tenant's disk cache process, which then read CubDB
# on the caller's behalf. Since CubDB already serves reads concurrently from
# any process, funneling every read through one GenServer per tenant
# serialized reads behind each other (and behind puts/evictions handled by
# that same process) for no reason. `get/2` and `peek_meta/2` now call
# `CubDB.fetch/2` directly using a pid cached in `:persistent_term`.
#
# This benchmark starts a real tenant disk cache, seeds it with entries, and
# measures the aggregate throughput of many concurrent readers hammering
# `DiskCache.get/2` at once — the case the GenServer bottleneck hurt most.
#
# Run with:
#
#     mix run apps/restdis/bench/disk_cache_concurrent_read_bench.exs

Application.ensure_all_started(:restdis)

alias Restdis.Cache.DiskCache
alias Restdis.Cache.Key
alias Restdis.Cache.TenantSupervisor

defmodule Restdis.Bench.DiskCacheConcurrentRead do
  @moduledoc false

  def run_concurrent_reads(tenant_id, keys, readers, reads_per_reader) do
    keys_count = length(keys)

    1..readers
    |> Enum.map(fn _ ->
      Task.async(fn ->
        Enum.each(1..reads_per_reader, fn i ->
          key = Enum.at(keys, rem(i, keys_count))
          {:ok, _} = DiskCache.get(tenant_id, key)
        end)
      end)
    end)
    |> Enum.each(&Task.await(&1, :infinity))
  end
end

alias Restdis.Bench.DiskCacheConcurrentRead, as: B

seed_count = 500
readers = 20
reads_per_reader = 2_000

tenant_id = "bench_dc_#{System.unique_integer([:positive])}"
TenantSupervisor.ensure_started(tenant_id)

keys =
  Enum.map(1..seed_count, fn i ->
    key = Key.build(:table, "products_#{i}", %{})
    DiskCache.put(tenant_id, key, %{"id" => i, "payload" => :crypto.strong_rand_bytes(256)})
    key
  end)

IO.puts(
  "\n=== #{readers} concurrent readers x #{reads_per_reader} reads each " <>
    "(#{seed_count} seeded keys) ==="
)

{elapsed_us, :ok} =
  :timer.tc(fn -> B.run_concurrent_reads(tenant_id, keys, readers, reads_per_reader) end)

total_reads = readers * reads_per_reader
elapsed_ms = elapsed_us / 1_000
reads_per_sec = total_reads / (elapsed_us / 1_000_000)

IO.puts("total reads: #{total_reads}")
IO.puts("elapsed: #{Float.round(elapsed_ms, 1)} ms")
IO.puts("throughput: #{Float.round(reads_per_sec, 0)} reads/sec")

Restdis.Cache.flush_tenant(tenant_id)
