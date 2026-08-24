defmodule SupaCacherReplicator.Subscription do
  @moduledoc """
  Per-dataset process owning the KV entries of one replicated table.
  """

  use GenServer

  require Logger

  alias SupaCacherReplicator.Dataset
  alias SupaCacherReplicator.Origin

  @default_page_size 1_000
  @default_page_delay_ms 50

  @doc """
  Returns the child spec of the subscription for `dataset`.
  """
  @spec child_spec(Dataset.t()) :: Supervisor.child_spec()
  def child_spec(%Dataset{} = dataset) do
    %{
      id: {__MODULE__, Dataset.registry_key(dataset)},
      start: {__MODULE__, :start_link, [dataset]},
      restart: :transient
    }
  end

  @doc """
  Starts the subscription of `dataset` and loads its initial result set.
  """
  @spec start_link(Dataset.t()) :: GenServer.on_start()
  def start_link(%Dataset{} = dataset) do
    GenServer.start_link(__MODULE__, dataset, name: via(dataset))
  end

  @doc """
  Re-fetches the row `pk` from the origin and updates its KV entry in place.
  """
  @spec refresh_row(Dataset.t(), term()) :: :ok
  def refresh_row(%Dataset{} = dataset, pk) do
    GenServer.cast(via(dataset), {:refresh_row, to_string(pk)})
  end

  @doc """
  Removes the KV entry of the row `pk`.
  """
  @spec delete_row(Dataset.t(), term()) :: :ok
  def delete_row(%Dataset{} = dataset, pk) do
    GenServer.cast(via(dataset), {:delete_row, to_string(pk)})
  end

  @doc """
  Runs a full diff against the origin and returns the number of stale entries removed.
  """
  @spec reconcile(Dataset.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def reconcile(%Dataset{} = dataset) do
    GenServer.call(via(dataset), :reconcile, :infinity)
  end

  @doc """
  Returns the primary keys currently replicated for `dataset`.
  """
  @spec primary_keys(Dataset.t()) :: [String.t()]
  def primary_keys(%Dataset{} = dataset) do
    GenServer.call(via(dataset), :primary_keys, :infinity)
  end

  @doc """
  Blocks until the initial load of `dataset` has completed.
  """
  @spec await_loaded(Dataset.t()) :: :ok
  def await_loaded(%Dataset{} = dataset) do
    GenServer.call(via(dataset), :await_loaded, :infinity)
  end

  @impl GenServer
  def init(%Dataset{} = dataset) do
    {:ok, %{dataset: dataset, pks: MapSet.new()}, {:continue, :initial_load}}
  end

  @impl GenServer
  def handle_continue(:initial_load, state) do
    case load_all(state.dataset) do
      {:ok, rows} ->
        pks = store_rows(state.dataset, rows)

        :telemetry.execute(
          [:supa_cacher_replicator, :subscription, :loaded],
          %{rows: MapSet.size(pks)},
          %{tenant_id: state.dataset.tenant_id, table: state.dataset.table}
        )

        {:noreply, %{state | pks: pks}}

      {:error, reason} ->
        Logger.warning(
          "[SupaCacherReplicator] initial load of #{state.dataset.table} failed: #{inspect(reason)}"
        )

        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_cast({:refresh_row, pk}, state) do
    {:noreply, do_refresh_row(state, pk)}
  end

  def handle_cast({:delete_row, pk}, state) do
    SupaCacherCache.delete(state.dataset.tenant_id, Dataset.cache_key(state.dataset, pk))
    {:noreply, %{state | pks: MapSet.delete(state.pks, pk)}}
  end

  @impl GenServer
  def handle_call(:await_loaded, _from, state), do: {:reply, :ok, state}

  def handle_call(:primary_keys, _from, state) do
    {:reply, MapSet.to_list(state.pks), state}
  end

  def handle_call(:reconcile, _from, state) do
    case load_all(state.dataset) do
      {:ok, rows} ->
        fresh_pks = store_rows(state.dataset, rows)
        stale = MapSet.difference(state.pks, fresh_pks)

        Enum.each(stale, fn pk ->
          SupaCacherCache.delete(state.dataset.tenant_id, Dataset.cache_key(state.dataset, pk))
        end)

        :telemetry.execute(
          [:supa_cacher_replicator, :reconcile, :completed],
          %{rows: MapSet.size(fresh_pks), stale: MapSet.size(stale)},
          %{tenant_id: state.dataset.tenant_id, table: state.dataset.table}
        )

        {:reply, {:ok, MapSet.size(stale)}, %{state | pks: fresh_pks}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp do_refresh_row(state, pk) do
    case Origin.fetch_row(state.dataset, pk) do
      {:ok, row} ->
        put_row(state.dataset, pk, row)
        %{state | pks: MapSet.put(state.pks, pk)}

      :not_found ->
        SupaCacherCache.delete(state.dataset.tenant_id, Dataset.cache_key(state.dataset, pk))
        %{state | pks: MapSet.delete(state.pks, pk)}

      {:error, reason} ->
        Logger.warning(
          "[SupaCacherReplicator] refresh of #{state.dataset.table}:#{pk} failed: #{inspect(reason)}"
        )

        state
    end
  end

  defp load_all(dataset), do: load_all(dataset, 0, [])

  defp load_all(dataset, offset, acc) do
    page_size = page_size()

    case Origin.list_page(dataset, offset, page_size) do
      {:ok, rows} when length(rows) < page_size ->
        {:ok, acc ++ rows}

      {:ok, rows} ->
        Process.sleep(page_delay_ms())
        load_all(dataset, offset + page_size, acc ++ rows)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp store_rows(dataset, rows) do
    Enum.reduce(rows, MapSet.new(), fn row, acc ->
      case Dataset.pk_of(dataset, row) do
        nil ->
          acc

        pk ->
          put_row(dataset, pk, row)
          MapSet.put(acc, pk)
      end
    end)
  end

  defp put_row(dataset, pk, row) do
    SupaCacherCache.put(dataset.tenant_id, Dataset.cache_key(dataset, pk), row,
      primary_keys: [pk]
    )
  end

  defp via(dataset) do
    {:via, Registry, {SupaCacherReplicator.Registry, Dataset.registry_key(dataset)}}
  end

  defp page_size do
    Application.get_env(:supa_cacher_replicator, :page_size, @default_page_size)
  end

  defp page_delay_ms do
    Application.get_env(:supa_cacher_replicator, :page_delay_ms, @default_page_delay_ms)
  end
end
