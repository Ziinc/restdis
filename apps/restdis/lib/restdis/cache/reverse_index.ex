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
  Starts the reverse index for the tenant given in `opts` (`:name`, `:tenant_id`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    tenant_id = Keyword.fetch!(opts, :tenant_id)

    GenServer.start_link(__MODULE__, tenant_id,
      name: TenantRegistry.via(name, tenant_id, :reverse_index)
    )
  end

  @doc """
  Records that `key` depends on the row `{table, pk}`.
  """
  @spec add(atom(), String.t(), table_name(), primary_key(), Key.t()) :: :ok
  def add(name, tenant_id, table, pk, key) do
    GenServer.call(TenantRegistry.via(name, tenant_id, :reverse_index), {:add, table, pk, key})
  end

  @doc """
  Drops the row `{table, pk}` and returns the cache keys that depended on it.
  """
  @spec purge_row(atom(), String.t(), table_name(), primary_key()) :: [Key.t()]
  def purge_row(name, tenant_id, table, pk) do
    GenServer.call(
      TenantRegistry.via(name, tenant_id, :reverse_index),
      {:purge_row, table, pk}
    )
  end

  @doc """
  Drops every row dependency recorded for `key`.
  """
  @spec purge_key(atom(), String.t(), Key.t()) :: :ok
  def purge_key(name, tenant_id, key) do
    GenServer.cast(TenantRegistry.via(name, tenant_id, :reverse_index), {:purge_key, key})
  end

  @doc """
  Drops every row of `table` and returns the cache keys that depended on them.
  """
  @spec purge_table(atom(), String.t(), table_name()) :: [Key.t()]
  def purge_table(name, tenant_id, table) do
    GenServer.call(TenantRegistry.via(name, tenant_id, :reverse_index), {:purge_table, table})
  end

  @doc """
  Records that `key` holds a list (array) response for `table`.

  A newly inserted row has no primary key entry to purge by, so list-scoped
  keys are tracked separately to let inserts bust them.
  """
  @spec add_list_key(atom(), String.t(), table_name(), Key.t()) :: :ok
  def add_list_key(name, tenant_id, table, key) do
    GenServer.cast(
      TenantRegistry.via(name, tenant_id, :reverse_index),
      {:add_list_key, table, key}
    )
  end

  @doc """
  Drops every list key recorded for `table` and returns the cache keys that depended on them.
  """
  @spec purge_list_keys(atom(), String.t(), table_name()) :: [Key.t()]
  def purge_list_keys(name, tenant_id, table) do
    GenServer.call(TenantRegistry.via(name, tenant_id, :reverse_index), {:purge_list_keys, table})
  end

  @impl GenServer
  def init(tenant_id) do
    fwd = :ets.new(:reverse_index_fwd, [:bag, :public, read_concurrency: true])
    rev = :ets.new(:reverse_index_rev, [:bag, :public, read_concurrency: true])
    list_keys = :ets.new(:reverse_index_list_keys, [:bag, :public, read_concurrency: true])
    {:ok, %{fwd: fwd, rev: rev, list_keys: list_keys, tenant_id: tenant_id}}
  end

  @impl GenServer
  def handle_call({:add, table, pk, key}, _from, %{fwd: fwd, rev: rev} = state) do
    :ets.insert(fwd, {{table, pk}, key})
    :ets.insert(rev, {key, {table, pk}})
    {:reply, :ok, state}
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
          [:restdis, :reverse_index, :miss],
          %{count: 1},
          %{tenant_id: tenant_id, table: table}
        )

      _ ->
        :telemetry.execute(
          [:restdis, :reverse_index, :hit],
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

  @impl GenServer
  def handle_call(
        {:purge_list_keys, table},
        _from,
        %{fwd: fwd, rev: rev, list_keys: list_keys} = state
      ) do
    keys =
      :ets.lookup(list_keys, table)
      |> Enum.map(fn {_, key} -> key end)
      |> Enum.uniq()

    :ets.match_delete(list_keys, {table, :_})

    Enum.each(keys, fn key ->
      pairs = :ets.lookup(rev, key) |> Enum.map(fn {_, pair} -> pair end)

      Enum.each(pairs, fn {t, pk} ->
        :ets.delete_object(fwd, {{t, pk}, key})
      end)

      :ets.delete(rev, key)
    end)

    {:reply, keys, state}
  end

  @impl GenServer
  def handle_cast({:add_list_key, table, key}, %{list_keys: list_keys} = state) do
    :ets.insert(list_keys, {table, key})
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
end
