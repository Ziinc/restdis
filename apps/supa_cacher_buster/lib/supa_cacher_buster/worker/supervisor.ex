defmodule SupaCacherBuster.Worker.Supervisor do
  @moduledoc """
  DynamicSupervisor for Worker tasks with per-tenant concurrency backpressure.

  Each event is checked against a per-tenant semaphore (counter). When a tenant
  exceeds its cap, the event is dropped and a coalesce counter for
  `(tenant_id, table)` is bumped. A separate sweeper (`CoalesceSweeper`)
  periodically converts these coalesced buckets into a coarse
  `Restdis.Cache.flush_table/2` call.

  Owns two named ETS tables:

    * `:supa_cacher_buster_tenant_semaphores` — `{tenant_id, counter_ref}`
    * `:supa_cacher_buster_coalesce`          — `{{tenant_id, table}, count}`
  """

  use DynamicSupervisor

  alias SupaCacherBuster.TenantTableConfig
  alias SupaCacherBuster.WAL.Event

  @max_children 5_000
  @default_per_tenant_cap 50

  @semaphores_table :supa_cacher_buster_tenant_semaphores
  @coalesce_table :supa_cacher_buster_coalesce

  @infra_schema "public"
  @tenants_table "tenants"
  @table_config_table "tenant_table_config"

  @doc """
  Returns the name of the ETS table holding per-tenant semaphores.
  """
  @spec semaphores_table() :: atom()
  def semaphores_table, do: @semaphores_table

  @doc """
  Returns the name of the ETS table holding coalesced `(tenant_id, table)` counts.
  """
  @spec coalesce_table() :: atom()
  def coalesce_table, do: @coalesce_table

  @doc """
  Starts the worker supervisor and its ETS tables.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl DynamicSupervisor
  def init(_opts) do
    ensure_table(@semaphores_table, [:set, :public, :named_table, read_concurrency: true])

    ensure_table(@coalesce_table, [
      :set,
      :public,
      :named_table,
      write_concurrency: true
    ])

    DynamicSupervisor.init(strategy: :one_for_one, max_children: @max_children)
  end

  defp ensure_table(name, opts) do
    :ets.new(name, opts)
  rescue
    ArgumentError -> name
  end

  @doc """
  Runs `event` in a worker, dropping it when the tenant is over its concurrency cap.
  """
  @spec start_worker(Event.t()) :: :ok
  @spec start_worker(Event.t(), (Event.t() -> any())) :: :ok
  def start_worker(event, runner \\ &SupaCacherBuster.Worker.run/1)

  # Infra tables and DDL messages bypass backpressure (low volume).
  def start_worker(%Event{schema: @infra_schema, table: @tenants_table} = event, runner) do
    spawn_unmetered(event, runner)
  end

  def start_worker(%Event{schema: @infra_schema, table: @table_config_table} = event, runner) do
    spawn_unmetered(event, runner)
  end

  def start_worker(%Event{op: :message} = event, runner) do
    spawn_unmetered(event, runner)
  end

  def start_worker(%Event{} = event, runner) do
    case TenantTableConfig.lookup(event.schema, event.table) do
      {:ok, %{tenant_id: tenant_id}} ->
        if try_acquire(tenant_id) do
          spawn_metered(event, runner, tenant_id)
        else
          coalesce(tenant_id, event.table)
        end

        :ok

      :not_found ->
        :ok
    end
  end

  defp spawn_unmetered(event, runner) do
    spec = %{
      id: :worker,
      start: {Task, :start_link, [fn -> runner.(event) end]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
  end

  defp spawn_metered(event, runner, tenant_id) do
    spec = %{
      id: :worker,
      start:
        {Task, :start_link,
         [
           fn ->
             try do
               runner.(event)
             after
               release(tenant_id)
             end
           end
         ]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, _} ->
        :ok

      {:error, _} ->
        release(tenant_id)
        :ok
    end
  end

  defp coalesce(tenant_id, table) do
    key = {tenant_id, table}
    :ets.update_counter(@coalesce_table, key, {2, 1}, {key, 0})

    :telemetry.execute(
      [:supa_cacher_buster, :backpressure, :triggered],
      %{count: 1},
      %{tenant_id: tenant_id, table: table}
    )

    :ok
  end

  defp try_acquire(tenant_id) do
    cap = per_tenant_cap()
    ref = counter_ref(tenant_id)
    :counters.add(ref, 1, 1)
    val = :counters.get(ref, 1)

    if val > cap do
      :counters.sub(ref, 1, 1)
      false
    else
      true
    end
  end

  defp release(tenant_id) do
    case :ets.lookup(@semaphores_table, tenant_id) do
      [{^tenant_id, ref}] -> :counters.sub(ref, 1, 1)
      [] -> :ok
    end
  end

  defp counter_ref(tenant_id) do
    case :ets.lookup(@semaphores_table, tenant_id) do
      [{^tenant_id, ref}] ->
        ref

      [] ->
        ref = :counters.new(1, [:write_concurrency])
        # insert_new prevents a race from clobbering an existing ref
        case :ets.insert_new(@semaphores_table, {tenant_id, ref}) do
          true ->
            ref

          false ->
            [{^tenant_id, existing}] = :ets.lookup(@semaphores_table, tenant_id)
            existing
        end
    end
  end

  defp per_tenant_cap do
    Application.get_env(:supa_cacher_buster, :worker_per_tenant_cap, @default_per_tenant_cap)
  end
end
