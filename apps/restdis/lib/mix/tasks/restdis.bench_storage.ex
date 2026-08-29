defmodule Mix.Tasks.Restdis.BenchStorage do
  @moduledoc """
  Benchmarks the `Restdis.Cache.Storage` backends (CubDB and FeoxDB) side by
  side, driving each with the same put/get/delete workload against its own
  temporary data directory.

      mix restdis.bench_storage
      mix restdis.bench_storage --entries 50000 --value-bytes 512

  Both backends run in the same invocation so results are comparable
  without a separate config flip between runs.
  """

  use Mix.Task

  @shortdoc "Benchmarks the CubDB and FeoxDB storage backends side by side"

  @backends [
    cubdb: Restdis.Cache.Storage.CubDB,
    feoxdb: Restdis.Cache.Storage.FeoxDB
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [entries: :integer, value_bytes: :integer],
        aliases: [n: :entries]
      )

    entries = Keyword.get(opts, :entries, 10_000)
    value_bytes = Keyword.get(opts, :value_bytes, 128)
    value = :crypto.strong_rand_bytes(value_bytes)
    keys = for i <- 1..entries, do: "bench:#{i}"

    Mix.shell().info("Benchmarking #{entries} entries (#{value_bytes}-byte values) per backend\n")

    results =
      for {label, backend} <- @backends do
        {label, run_backend(label, backend, keys, value)}
      end

    print_table(results)
  end

  defp run_backend(label, backend, keys, value) do
    tmp_dir = Path.join(System.tmp_dir!(), "restdis_bench_#{label}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    result =
      try do
        {:ok, handle} = backend.open(data_dir: tmp_dir)

        put_us = time_us(fn -> Enum.each(keys, &backend.put(handle, &1, value)) end)
        get_us = time_us(fn -> Enum.each(keys, &backend.fetch(handle, &1)) end)
        select_us = time_us(fn -> handle |> backend.select() |> Enum.count() end)
        delete_us = time_us(fn -> Enum.each(keys, &backend.delete(handle, &1)) end)

        backend.close(handle)

        %{put: put_us, get: get_us, select: select_us, delete: delete_us}
      rescue
        error -> {:error, Exception.format(:error, error, __STACKTRACE__)}
      after
        File.rm_rf!(tmp_dir)
      end

    result
  end

  defp time_us(fun) do
    {us, _result} = :timer.tc(fun)
    us
  end

  defp print_table(results) do
    Enum.each(results, fn
      {label, {:error, reason}} ->
        Mix.shell().error("#{label}: failed — #{reason}")

      {label, %{put: put_us, get: get_us, select: select_us, delete: delete_us}} ->
        Mix.shell().info("""
        #{label}:
          put:    #{format(put_us)}
          get:    #{format(get_us)}
          select: #{format(select_us)}
          delete: #{format(delete_us)}
        """)
    end)
  end

  defp format(us), do: "#{Float.round(us / 1000, 2)} ms total"
end
