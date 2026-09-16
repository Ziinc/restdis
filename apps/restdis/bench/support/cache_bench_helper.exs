# Shared setup for the cache-hot-path benchmarks in this directory.
#
# `Code.require_file/1`'d by each `*_bench.exs` script rather than pulled in
# as an app dependency: these scripts run via `mix run <path>`, standalone,
# outside `mix test`.

defmodule Restdis.Bench.CacheHelper do
  @moduledoc false

  @doc """
  Starts the cache supervision tree pointed at a scratch `data_dir`, and
  points config at the no-op stub origin and a nil replication transport so
  benchmarks never touch a real PostgREST origin or Erlang distribution.

  Idempotent: safe to call once per script even though `mix run` loads the
  whole `:restdis` application first.
  """
  @spec setup_app(String.t()) :: :ok
  def setup_app(data_dir) do
    File.rm_rf!(data_dir)
    File.mkdir_p!(data_dir)

    Application.put_env(:restdis, :cache_data_dir, data_dir)
    Application.put_env(:restdis, :origin, Restdis.Cache.Origin.Stub)
    Application.put_env(:restdis, :replication_transport, nil)

    case Restdis.Cache.Supervisor.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  @doc "Starts and returns a freshly named tenant id, unique across calls."
  @spec fresh_tenant(String.t()) :: String.t()
  def fresh_tenant(prefix \\ "bench") do
    tenant_id = "#{prefix}#{System.unique_integer([:positive])}"
    Restdis.Cache.TenantSupervisor.ensure_started(tenant_id)
    tenant_id
  end

  @doc "A PostgREST-shaped row of roughly `payload_bytes` of extra padding."
  @spec row(term(), non_neg_integer()) :: map()
  def row(id, payload_bytes \\ 200) do
    %{
      "id" => id,
      "name" => "row_#{id}",
      "payload" => :crypto.strong_rand_bytes(payload_bytes) |> Base.encode64()
    }
  end

  @doc "`count` PostgREST-shaped rows, as a single cached list response."
  @spec rows(non_neg_integer(), non_neg_integer()) :: [map()]
  def rows(count, payload_bytes \\ 200) do
    Enum.map(1..count, &row(&1, payload_bytes))
  end

  @doc "Reports a scalar measurement in the same shape as the CubDB bench."
  @spec report(String.t(), term()) :: :ok
  def report(label, value), do: IO.puts("#{label}: #{inspect(value)}")
end
