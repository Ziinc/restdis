defmodule Restdis.Cache.ReverseIndex do
  @moduledoc """
  Maps `{table, primary key}` pairs back to the cache keys that depend on them.
  """

  use GenServer

  alias Restdis.Cache.Key
  alias Restdis.Cache.TenantRegistry

  @type table_name :: String.t()
  @type primary_key :: term()

  @doc """
  Starts the reverse index for the tenant given in `opts`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    tenant_id = Keyword.fetch!(opts, :tenant_id)

    GenServer.start_link(__MODULE__, tenant_id,
      name: TenantRegistry.via(tenant_id, :reverse_index)
    )
  end

  @doc """
  Records that `key` depends on the row `{table, pk}`.
  """
  @spec add(String.t(), table_name(), primary_key(), Key.t()) :: :ok
  def add(tenant_id, table, pk, key) do
    GenServer.cast(TenantRegistry.via(tenant_id, :reverse_index), {:add, table, pk, key})
  end

  @doc """
  Drops the row `{table, pk}` and returns the cache keys that depended on it.
  """
  @spec purge_row(String.t(), table_name(), primary_key()) :: [Key.t()]
  def purge_row(tenant_id, table, pk) do
    GenServer.call(TenantRegistry.via(tenant_id, :reverse_index), {:purge_row, table, pk})
  end

  @doc """
  Drops every row dependency recorded for `key`.
  """
  @spec purge_key(String.t(), Key.t()) :: :ok
  def purge_key(tenant_id, key) do
    GenServer.cast(TenantRegistry.via(tenant_id, :reverse_index), {:purge_key, key})
  end

  @doc """
  Drops every row of `table` and returns the cache keys that depended on them.
  """
  @spec purge_table(String.t(), table_name()) :: [Key.t()]
  def purge_table(tenant_id, table) do
    GenServer.call(TenantRegistry.via(tenant_id, :reverse_index), {:purge_table, table})
  end

  @impl GenServer
  def init(tenant_id) do
    fwd = :ets.new(:reverse_index_fwd, [:bag, :public, read_concurrency: true])
    rev = :ets.new(:reverse_index_rev, [:bag, :public, read_concurrency: true])
    {:ok, %{fwd: fwd, rev: rev, tenant_id: tenant_id}}
  end

  @impl GenServer
  def handle_cast({:add, table, pk, key}, %{fwd: fwd, rev: rev} = state) do
    :ets.insert(fwd, {{table, pk}, key})
    :ets.insert(rev, {key, {table, pk}})
    {:noreply, state}
  end

  @impl GenServer
  def handle_cast({:purge_key, key}, %{fwd: fwd, rev: rev} = state) do
    pairs = :ets.lookup(rev, key) |> Enum.map(fn {_, pair} -> pair end)

    Enum.each(pairs, fn {table, pk} ->
      :ets.delete_object(fwd, {{table, pk}, key})
    end)

    :ets.delete(rev, key)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(
        {:purge_row, table, pk},
        _from,
        %{fwd: fwd, rev: rev, tenant_id: tenant_id} = state
      ) do
    keys = :ets.lookup(fwd, {table, pk}) |> Enum.map(fn {_, key} -> key end)

    case keys do
      [] ->
        :telemetry.execute(
          [:restdis_buster, :reverse_index, :miss],
          %{count: 1},
          %{tenant_id: tenant_id, table: table}
        )

      _ ->
        :telemetry.execute(
          [:restdis_buster, :reverse_index, :hit],
          %{keys: length(keys)},
          %{tenant_id: tenant_id, table: table}
        )
    end

    Enum.each(keys, fn key ->
      :ets.delete_object(rev, {key, {table, pk}})
    end)

    :ets.delete(fwd, {table, pk})
    {:reply, keys, state}
  end

  @impl GenServer
  def handle_call({:purge_table, table}, _from, %{fwd: fwd, rev: rev} = state) do
    matches = :ets.match(fwd, {{table, :_}, :"$1"})
    cache_keys = matches |> Enum.flat_map(& &1) |> Enum.uniq()

    :ets.match_delete(fwd, {{table, :_}, :_})

    Enum.each(cache_keys, fn key ->
      :ets.match_delete(rev, {key, {table, :_}})
    end)

    {:reply, cache_keys, state}
  end
end
