# Shared setup for the cache-hot-path benchmarks in this directory.
#
# `Code.require_file/1`'d by each `*_bench.exs` script rather than pulled in
# as an app dependency: these scripts run via `mix run <path>`, standalone,
# outside `mix test`.

defmodule Restdis.Bench.CacheHelper do
  @moduledoc false

  alias Restdis.Cache.InstanceConfig
  alias Restdis.Cache.TenantSupervisor

  @name Restdis.Cache

  @doc "The cache instance name every benchmark runs against."
  @spec name() :: atom()
  def name, do: @name

  @doc """
  Starts `:restdis`'s dependencies and mounts the default cache instance
  pointed at a scratch `data_dir` and the no-op stub origin, so benchmarks
  never touch a real PostgREST origin.

  Scripts run under `mix run --no-start`: a plain `mix run` boots every
  umbrella app, and `restdis_server` mounts its own `Restdis.Cache` first,
  which `Restdis.Cache.Supervisor.start_link/1` then returns unchanged,
  ignoring the options given here. Extra `opts` (e.g. resource caps) are
  passed through to the supervisor.
  """
  @spec setup_app(String.t(), keyword()) :: :ok
  def setup_app(data_dir, opts \\ []) do
    {:ok, _apps} = Application.ensure_all_started(:restdis)
    File.rm_rf!(data_dir)
    File.mkdir_p!(data_dir)

    opts =
      Keyword.merge(
        [name: @name, data_dir: data_dir, origin: Restdis.Cache.Origin.Stub],
        opts
      )

    {:ok, _pid} = Restdis.Cache.Supervisor.start_link(opts)
    :ok
  end

  @doc "Overrides one resource cap (`:ets_cap_bytes`, `:disk_cap_bytes`) at runtime."
  @spec put_cap(atom(), pos_integer()) :: :ok
  def put_cap(field, value), do: InstanceConfig.put_field(@name, field, value)

  @doc "Starts and returns a freshly named tenant id, unique across calls."
  @spec fresh_tenant(String.t()) :: String.t()
  def fresh_tenant(prefix \\ "bench") do
    tenant_id = "#{prefix}#{System.unique_integer([:positive])}"
    TenantSupervisor.ensure_started(@name, tenant_id)
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
end
