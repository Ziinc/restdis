defmodule SupaCacherCache.ReverseIndex do
  use GenServer

  alias SupaCacherCache.Key
  alias SupaCacherCache.TenantRegistry

  @type table_name :: String.t()
  @type primary_key :: term()

  def start_link(opts) do
    tenant_id = Keyword.fetch!(opts, :tenant_id)

    GenServer.start_link(__MODULE__, tenant_id,
      name: TenantRegistry.via(tenant_id, :reverse_index)
    )
  end

  @spec add(String.t(), table_name(), primary_key(), Key.t()) :: :ok
  def add(tenant_id, table, pk, key) do
    GenServer.cast(TenantRegistry.via(tenant_id, :reverse_index), {:add, table, pk, key})
  end

  @spec purge_row(String.t(), table_name(), primary_key()) :: [Key.t()]
  def purge_row(tenant_id, table, pk) do
    GenServer.call(TenantRegistry.via(tenant_id, :reverse_index), {:purge_row, table, pk})
  end

  @spec purge_key(String.t(), Key.t()) :: :ok
  def purge_key(tenant_id, key) do
    GenServer.cast(TenantRegistry.via(tenant_id, :reverse_index), {:purge_key, key})
  end

  @impl GenServer
  def init(_tenant_id) do
    fwd = :ets.new(:reverse_index_fwd, [:bag, :public, read_concurrency: true])
    rev = :ets.new(:reverse_index_rev, [:bag, :public, read_concurrency: true])
    {:ok, %{fwd: fwd, rev: rev}}
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
  def handle_call({:purge_row, table, pk}, _from, %{fwd: fwd, rev: rev} = state) do
    keys = :ets.lookup(fwd, {table, pk}) |> Enum.map(fn {_, key} -> key end)

    Enum.each(keys, fn key ->
      :ets.delete_object(rev, {key, {table, pk}})
    end)

    :ets.delete(fwd, {table, pk})
    {:reply, keys, state}
  end
end
