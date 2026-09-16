# Tenant churn benchmark
#
# QueryCache used to publish its ETS table id and persist counter ref via
# `:persistent_term.put/2` on every tenant start, and `:persistent_term.erase/1`
# on every tenant stop (see git history of `query_cache.ex`). Every write to
# the persistent_term table forces a full sweep of the literal area across
# *every* process on the node (a global GC), so under tenant churn (short-
# lived tenants starting and stopping repeatedly) every other process on the
# node pays a latency spike, proportional to the number of processes and the
# size of their heaps, on every single tenant start/stop.
#
# This replaces that with values registered in the existing per-tenant
# `Restdis.Cache.TenantRegistry` (a `Registry`, i.e. a set of ordinary ETS
# tables), whose writes are local `:ets.insert/2` calls with no VM-wide
# effect, and which are cleaned up automatically when the owning process
# exits (fixing a second bug: a `:persistent_term` entry left dangling after
# a hard kill, since `QueryCache` never trapped exits and `terminate/2` is
# skipped on `:kill`).
#
# This benchmark starts a pool of unrelated "bystander" processes doing
# steady work, then runs a burst of simulated tenant churn concurrently
# using each strategy, and measures how much churn degrades bystander
# throughput.
#
# Run with:
#
#     mix run apps/restdis/bench/tenant_churn_bench.exs

defmodule Restdis.Bench.TenantChurn do
  @moduledoc false

  @doc """
  Spawns `count` bystander processes, each looping a cheap allocation for
  `duration_ms`, counting iterations. Returns a function that, once all
  bystanders finish, returns the total iterations observed -- called after
  `churn_fn` has run for the same `duration_ms`.
  """
  def start_bystanders(count, duration_ms) do
    parent = self()

    for i <- 1..count do
      spawn_link(fn ->
        deadline = System.monotonic_time(:millisecond) + duration_ms
        n = bystander_loop(deadline, 0)
        send(parent, {:bystander_done, i, n})
      end)
    end

    fn ->
      for _ <- 1..count do
        receive do
          {:bystander_done, _i, n} -> n
        after
          duration_ms + 5_000 -> 0
        end
      end
      |> Enum.sum()
    end
  end

  defp bystander_loop(deadline, n) do
    if System.monotonic_time(:millisecond) >= deadline do
      n
    else
      # Cheap, steady allocation work representative of normal request
      # handling (building small terms), so a global GC pause shows up as
      # lost iterations.
      _ = :erlang.term_to_binary(%{a: n, b: [1, 2, 3], c: "some request data"})
      bystander_loop(deadline, n + 1)
    end
  end

  @doc "Simulated tenant start/stop churn via :persistent_term (the old approach)."
  def persistent_term_churn(rounds) do
    for i <- 1..rounds do
      key = {:sc_qc_bench, i}
      :persistent_term.put(key, i)
      :persistent_term.put({:sc_persist_bench, i}, i)
      :persistent_term.erase(key)
      :persistent_term.erase({:sc_persist_bench, i})
    end

    :ok
  end

  @doc "Simulated tenant start/stop churn via Registry (the new approach)."
  def registry_churn(registry, rounds) do
    for i <- 1..rounds do
      pid =
        spawn(fn ->
          Registry.register(registry, {:qc_table_bench, i}, i)
          Registry.register(registry, {:qc_persist_bench, i}, i)

          receive do
            :stop -> :ok
          end
        end)

      send(pid, :stop)
      # Give the registry a moment to process the DOWN and clean up, mirroring
      # the async cleanup a real tenant stop would also incur.
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        1_000 -> :ok
      end
    end

    :ok
  end
end

alias Restdis.Bench.TenantChurn, as: B

{:ok, _} = Registry.start_link(keys: :unique, name: Restdis.Bench.ChurnRegistry)

bystander_count = 50
duration_ms = 2_000
churn_rounds = 500

report = fn label, iterations ->
  IO.puts("#{label}: #{iterations} bystander iterations in #{duration_ms}ms")
end

IO.puts("=== baseline: no churn ===")
await = B.start_bystanders(bystander_count, duration_ms)
Process.sleep(duration_ms)
report.("no churn", await.())

IO.puts("\n=== persistent_term churn (old approach) ===")
await = B.start_bystanders(bystander_count, duration_ms)
{churn_us, :ok} = :timer.tc(fn -> B.persistent_term_churn(churn_rounds) end)
Process.sleep(max(duration_ms - div(churn_us, 1000), 0))
report.("with persistent_term churn", await.())
IO.puts("#{churn_rounds} put+erase rounds took #{churn_us}us")

IO.puts("\n=== Registry churn (new approach) ===")
await = B.start_bystanders(bystander_count, duration_ms)

{churn_us, :ok} =
  :timer.tc(fn -> B.registry_churn(Restdis.Bench.ChurnRegistry, churn_rounds) end)

Process.sleep(max(duration_ms - div(churn_us, 1000), 0))
report.("with Registry churn", await.())
IO.puts("#{churn_rounds} register+stop rounds took #{churn_us}us")

IO.puts("""

Expect bystander throughput under persistent_term churn to be noticeably
lower than baseline and than Registry churn, since each persistent_term
put/erase performs a global GC of every process's heap.
""")
