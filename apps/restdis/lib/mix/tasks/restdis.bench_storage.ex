defmodule Mix.Tasks.Restdis.BenchStorage do
  @moduledoc """
  Benchmarks the `Restdis.Cache.Storage` backends (CubDB and FeoxDB) side by
  side with a real Redis server, driving each with the same put/get/delete
  workload.

      mix restdis.bench_storage
      mix restdis.bench_storage --entries 50000 --value-bytes 512
      mix restdis.bench_storage --redis-url redis://localhost:6379
      mix restdis.bench_storage --skip-redis

  CubDB and FeoxDB each get their own temporary on-disk data directory.
  Redis is driven through a real `Redix` client against a running
  `redis-server` (defaults to `redis://localhost:6379`); if it can't be
  reached, that arm is reported as skipped rather than failing the whole
  run. All three arms run in the same invocation so results are comparable
  without switching config between runs.
  """

  use Mix.Task

  @shortdoc "Benchmarks the CubDB and FeoxDB storage backends against a real Redis server"

  @storage_backends [
    cubdb: Restdis.Cache.Storage.CubDB,
    feoxdb: Restdis.Cache.Storage.FeoxDB
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [entries: :integer, value_bytes: :integer, redis_url: :string, skip_redis: :boolean],
        aliases: [n: :entries]
      )

    entries = Keyword.get(opts, :entries, 10_000)
    value_bytes = Keyword.get(opts, :value_bytes, 128)
    redis_url = Keyword.get(opts, :redis_url, "redis://localhost:6379")
    skip_redis? = Keyword.get(opts, :skip_redis, false)
    value = :crypto.strong_rand_bytes(value_bytes)
    keys = for i <- 1..entries, do: "bench:#{i}"

    Mix.shell().info("Benchmarking #{entries} entries (#{value_bytes}-byte values) per backend\n")

    storage_results =
      for {label, backend} <- @storage_backends do
        {label, run_storage_backend(label, backend, keys, value)}
      end

    redis_result = if skip_redis?, do: {:redis, {:skipped, "--skip-redis"}}, else: {:redis, run_redis(redis_url, keys, value)}

    print_table(storage_results ++ [redis_result])
  end

  defp run_storage_backend(label, backend, keys, value) do
    tmp_dir = Path.join(System.tmp_dir!(), "restdis_bench_#{label}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

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
  end

  defp run_redis(redis_url, keys, value) do
    case Redix.start_link(redis_url, sync_connect: true, exit_on_disconnection: false) do
      {:ok, conn} ->
        try do
          put_us =
            time_us(fn -> Enum.each(keys, &Redix.command!(conn, ["SET", &1, value])) end)

          get_us = time_us(fn -> Enum.each(keys, &Redix.command!(conn, ["GET", &1])) end)
          select_us = time_us(fn -> redis_scan_count(conn) end)
          delete_us = time_us(fn -> Enum.each(keys, &Redix.command!(conn, ["DEL", &1])) end)

          %{put: put_us, get: get_us, select: select_us, delete: delete_us}
        rescue
          error -> {:error, Exception.format(:error, error, __STACKTRACE__)}
        after
          GenServer.stop(conn)
        end

      {:error, reason} ->
        {:skipped, "could not connect to #{redis_url}: #{inspect(reason)}"}
    end
  end

  defp redis_scan_count(conn, cursor \\ "0", acc \\ 0) do
    case Redix.command!(conn, ["SCAN", cursor, "MATCH", "bench:*", "COUNT", "1000"]) do
      [next_cursor, matched] ->
        acc = acc + length(matched)
        if next_cursor == "0", do: acc, else: redis_scan_count(conn, next_cursor, acc)
    end
  end

  defp time_us(fun) do
    {us, _result} = :timer.tc(fun)
    us
  end

  defp print_table(results) do
    Enum.each(results, fn
      {label, {:skipped, reason}} ->
        Mix.shell().info("#{label}: skipped — #{reason}")

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
