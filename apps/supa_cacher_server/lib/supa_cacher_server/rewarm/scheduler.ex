defmodule SupaCacherServer.Rewarm.Scheduler do
  use GenServer

  alias SupaCacherCache.Key
  alias SupaCacherServer.PostgREST.Fetcher
  alias SupaCacherServer.TenantConfig

  defstruct [:key, :rewarm_s, :persist, :last_read_ms, :last_rewarm_ms, :next_due_ms]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    tenant_id = Keyword.fetch!(opts, :tenant_id)

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {SupaCacherServer.Rewarm.Registry, tenant_id}}
    )
  end

  @spec upsert(pid(), binary(), Key.t(), map()) :: :ok
  def upsert(pid, wire_key, key, policy) do
    GenServer.cast(pid, {:touch, wire_key, key, policy})
  end

  @spec policy_changed(pid(), binary(), Key.t(), map()) :: :ok
  def policy_changed(pid, wire_key, key, policy) do
    GenServer.call(pid, {:policy_changed, wire_key, key, policy})
  end

  @impl GenServer
  def init(opts) do
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    tick_ms = Application.get_env(:supa_cacher_server, :rewarm_tick_ms, 500)
    table = :ets.new(:rewarm_scheduler, [:set, :protected])
    schedule_tick(tick_ms)
    {:ok, %{tenant_id: tenant_id, table: table, tick_ms: tick_ms}}
  end

  @impl GenServer
  def handle_cast({:touch, wire_key, key, %{rewarm_s: rewarm_s, persist: persist}}, state) do
    now = mono_ms()

    entry =
      case :ets.lookup(state.table, wire_key) do
        [{^wire_key, existing}] ->
          %{existing |
            rewarm_s: rewarm_s,
            persist: persist,
            last_read_ms: now,
            next_due_ms: max(existing.next_due_ms, now + rewarm_s * 1000)}

        [] ->
          %__MODULE__{
            key: key,
            rewarm_s: rewarm_s,
            persist: persist,
            last_read_ms: now,
            last_rewarm_ms: nil,
            next_due_ms: now + rewarm_s * 1000
          }
      end

    :ets.insert(state.table, {wire_key, entry})
    {:noreply, state}
  end

  def handle_cast({:refetch_ok, wire_key, body, started_at_us}, state) do
    case :ets.lookup(state.table, wire_key) do
      [] ->
        {:noreply, state}

      [{^wire_key, entry}] ->
        ttl_ms =
          case TenantConfig.lookup_by_tenant_id(state.tenant_id) do
            {:ok, config} -> (config.default_ttl_s || 60) * 1000
            _ -> 60_000
          end

        SupaCacherCache.put(state.tenant_id, entry.key, body, ttl_ms: ttl_ms, persist: entry.persist)

        now_us = mono_us()

        :ets.insert(state.table, {wire_key, %{entry | last_rewarm_ms: mono_ms()}})

        :telemetry.execute(
          [:supa_cacher_server, :rewarm, :refetch],
          %{duration_us: now_us - started_at_us},
          %{tenant_id: state.tenant_id, key_ident: entry.key.ident}
        )

        {:noreply, state}
    end
  end

  def handle_cast({:refetch_err, wire_key, reason}, state) do
    :telemetry.execute(
      [:supa_cacher_server, :rewarm, :error],
      %{count: 1},
      %{tenant_id: state.tenant_id, reason: reason}
    )

    _ = wire_key
    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:policy_changed, wire_key, key, policy}, _from, state) do
    if is_nil(policy.rewarm_s) do
      :ets.delete(state.table, wire_key)
    else
      now = mono_ms()

      entry =
        case :ets.lookup(state.table, wire_key) do
          [{^wire_key, existing}] ->
            %{existing |
              rewarm_s: policy.rewarm_s,
              persist: policy.persist,
              next_due_ms: max(existing.next_due_ms, now + policy.rewarm_s * 1000)}

          [] ->
            %__MODULE__{
              key: key,
              rewarm_s: policy.rewarm_s,
              persist: policy.persist,
              last_read_ms: now,
              last_rewarm_ms: nil,
              next_due_ms: now + policy.rewarm_s * 1000
            }
        end

      :ets.insert(state.table, {wire_key, entry})
    end

    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    now = mono_ms()

    due =
      :ets.select(state.table, [
        {{:"$1", :"$2"}, [{:"=<", {:map_get, :next_due_ms, :"$2"}, now}], [{{:"$1", :"$2"}}]}
      ])

    Enum.each(due, fn {wire_key, entry} ->
      process_due_entry(state, wire_key, entry, now)
    end)

    schedule_tick(state.tick_ms)
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    :ets.delete(state.table)
    :ok
  end

  defp process_due_entry(state, wire_key, entry, now) do
    cold? =
      not is_nil(entry.last_rewarm_ms) and
        now - entry.last_read_ms > entry.rewarm_s * 1000 and
        not entry.persist

    if cold? do
      SupaCacherCache.delete(state.tenant_id, entry.key)
      :ets.delete(state.table, wire_key)

      :telemetry.execute(
        [:supa_cacher_server, :rewarm, :evicted],
        %{count: 1},
        %{tenant_id: state.tenant_id, reason: :cold}
      )
    else
      :ets.insert(state.table, {wire_key, %{entry | next_due_ms: now + entry.rewarm_s * 1000}})

      scheduler_pid = self()
      tenant_id = state.tenant_id

      Task.Supervisor.start_child(SupaCacherServer.Rewarm.TaskSupervisor, fn ->
        started_at_us = mono_us()

        case TenantConfig.lookup_by_tenant_id(tenant_id) do
          {:ok, config} ->
            case Fetcher.fetch(tenant_id, entry.key, config) do
              {:ok, body} ->
                GenServer.cast(scheduler_pid, {:refetch_ok, wire_key, body, started_at_us})

              {:error, reason} ->
                GenServer.cast(scheduler_pid, {:refetch_err, wire_key, reason})
            end

          {:error, _} ->
            GenServer.cast(scheduler_pid, {:refetch_err, wire_key, :no_config})
        end
      end)
    end
  end

  defp schedule_tick(tick_ms) do
    Process.send_after(self(), :tick, tick_ms)
  end

  defp mono_ms, do: System.monotonic_time(:millisecond)
  defp mono_us, do: System.monotonic_time(:microsecond)
end
