# CubDB compaction benchmark
#
# Exercises a CubDB store the same way Restdis.Cache.DiskCache does (a
# `{:v1, %{value: value, persist: persist}}` envelope keyed by opaque binary
# keys) under a sustained mixed workload of puts, deletes, and reads at a
# few data volumes, then measures the effect of `CubDB.compact/1` on:
#
#   * write/read/delete throughput before vs. after compaction
#   * on-disk size before vs. after compaction
#   * wall-clock time `CubDB.compact/1` itself takes
#
# Run with:
#
#     mix run apps/restdis/bench/cubdb_compaction_bench.exs
#
# This is a standalone Benchee script (not an ExUnit test) and is not part
# of `mix test`.

{:ok, _} = Application.ensure_all_started(:cubdb)

defmodule Restdis.Bench.CubdbCompaction do
  @moduledoc false

  @doc "Fresh CubDB store at `dir`, returns `{:ok, pid}`."
  def open(dir) do
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    CubDB.start_link(data_dir: dir)
  end

  @doc "Puts `count` entries, encoded like Restdis.Cache.DiskCache does."
  def seed(cubdb, count, value_size) do
    value = :crypto.strong_rand_bytes(value_size)

    Enum.each(1..count, fn i ->
      :ok = CubDB.put(cubdb, "tenant:key:#{i}", {:v1, %{value: value, persist: rem(i, 5) == 0}})
    end)
  end

  @doc """
  Runs one round of the sustained mixed workload: `writes` new puts,
  `deletes` deletes of already-written keys (creating CubDB btree
  garbage — the raw material compaction reclaims), and `reads` fetches.
  """
  def mixed_round(cubdb, base, writes, deletes, reads, value_size) do
    value = :crypto.strong_rand_bytes(value_size)

    Enum.each(1..writes, fn i ->
      :ok = CubDB.put(cubdb, "tenant:key:#{base + i}", {:v1, %{value: value, persist: false}})
    end)

    Enum.each(1..deletes, fn i ->
      :ok = CubDB.delete(cubdb, "tenant:key:#{base - i}")
    end)

    Enum.each(1..reads, fn i ->
      CubDB.fetch(cubdb, "tenant:key:#{base + rem(i, max(writes, 1))}")
    end)
  end

  @doc "Sums file sizes under `dir`."
  def disk_size(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&File.stat!(&1).size)
    |> Enum.sum()
  end
end

alias Restdis.Bench.CubdbCompaction, as: B

results_dir = Path.join(System.tmp_dir!(), "restdis_bench_cubdb")
File.rm_rf!(results_dir)
File.mkdir_p!(results_dir)

value_size = 256
volumes = [1_000, 10_000, 50_000]

report = fn label, value -> IO.puts("#{label}: #{value}") end

Enum.each(volumes, fn volume ->
  dir = Path.join(results_dir, "vol_#{volume}")
  {:ok, cubdb} = B.open(dir)

  IO.puts("\n=== volume=#{volume} entries, value_size=#{value_size} bytes ===")

  # Seed the store, then run several rounds of a sustained mixed workload
  # (write-heavy with steady deletes, like TTL eviction / cache churn) so
  # garbage accumulates in the CubDB file before compaction.
  B.seed(cubdb, volume, value_size)

  rounds = 20
  writes_per_round = div(volume, 20)
  deletes_per_round = div(volume, 40)
  reads_per_round = div(volume, 10)

  Enum.each(1..rounds, fn round ->
    B.mixed_round(
      cubdb,
      volume + round * writes_per_round,
      writes_per_round,
      deletes_per_round,
      reads_per_round,
      value_size
    )
  end)

  size_before = B.disk_size(dir)
  report.("disk size before compaction (bytes)", size_before)

  Benchee.run(
    %{
      "put" => fn ->
        CubDB.put(
          cubdb,
          "tenant:key:bench_put",
          {:v1, %{value: :crypto.strong_rand_bytes(value_size), persist: false}}
        )
      end,
      "fetch (hit)" => fn -> CubDB.fetch(cubdb, "tenant:key:1") end,
      "fetch (miss)" => fn -> CubDB.fetch(cubdb, "tenant:key:does_not_exist") end,
      "delete" => fn -> CubDB.delete(cubdb, "tenant:key:bench_delete_noop") end
    },
    time: 2,
    warmup: 1,
    memory_time: 0,
    print: [configuration: false],
    title: "volume=#{volume} BEFORE compaction"
  )

  compact_fn = fn ->
    case CubDB.compact(cubdb) do
      :ok ->
        :ok

      {:error, :pending_compaction} ->
        # A compaction from a previous round (or auto-compaction) is still
        # running; wait for it to finish, then this is effectively a no-op
        # (CubDB only needs one compaction pass at a time).
        Process.sleep(50)
        :already_compacting
    end
  end

  {compact_us, _result} = :timer.tc(compact_fn)
  report.("CubDB.compact/1 duration (us)", compact_us)

  # Compaction finishes asynchronously (the old file is swapped once the
  # compactor process completes); poll until CubDB reports it's done.
  Enum.each(1..100, fn _ ->
    if CubDB.compacting?(cubdb), do: Process.sleep(50)
  end)

  size_after = B.disk_size(dir)
  report.("disk size after compaction (bytes)", size_after)

  reduction_pct =
    if size_before > 0, do: Float.round((1 - size_after / size_before) * 100, 1), else: 0.0

  report.("disk size reduction (%)", reduction_pct)

  Benchee.run(
    %{
      "put" => fn ->
        CubDB.put(
          cubdb,
          "tenant:key:bench_put",
          {:v1, %{value: :crypto.strong_rand_bytes(value_size), persist: false}}
        )
      end,
      "fetch (hit)" => fn -> CubDB.fetch(cubdb, "tenant:key:1") end,
      "fetch (miss)" => fn -> CubDB.fetch(cubdb, "tenant:key:does_not_exist") end,
      "delete" => fn -> CubDB.delete(cubdb, "tenant:key:bench_delete_noop") end
    },
    time: 2,
    warmup: 1,
    memory_time: 0,
    print: [configuration: false],
    title: "volume=#{volume} AFTER compaction"
  )

  CubDB.stop(cubdb)
end)

File.rm_rf!(results_dir)
