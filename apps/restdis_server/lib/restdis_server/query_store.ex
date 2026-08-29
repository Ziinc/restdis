defmodule RestdisServer.QueryStore do
  @moduledoc """
  Per-tenant store of the raw query string a cache key was parsed from.

  `Restdis.Cache.Key` only carries a hash of the decoded params (so cache
  entries stay small and cheap to compare), which means the key itself
  cannot be used to reconstruct the original query string. This store keeps
  the raw query string keyed by `{tenant_id, wire_key}` so the fetcher can
  forward it to PostgREST on cache-miss, rewarm, and fallback fetches.
  """

  use GenServer

  @table :restdis_query_store

  @doc """
  Starts the query store and its ETS table.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the raw query string stored for `wire_key`, or `""` when unset.
  """
  @spec get(String.t(), String.t()) :: String.t()
  def get(tenant_id, wire_key) do
    case :ets.lookup(@table, {tenant_id, wire_key}) do
      [{_, query_string}] -> query_string
      [] -> ""
    end
  end

  @doc """
  Stores the raw query string of `wire_key`.
  """
  @spec put(String.t(), String.t(), String.t()) :: :ok
  def put(tenant_id, wire_key, query_string) do
    :ets.insert(@table, {{tenant_id, wire_key}, query_string || ""})
    :ok
  end

  @doc """
  Drops the stored query string of `wire_key`.
  """
  @spec delete(String.t(), String.t()) :: :ok
  def delete(tenant_id, wire_key) do
    :ets.delete(@table, {tenant_id, wire_key})
    :ok
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :set,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, %{}}
  end
end
