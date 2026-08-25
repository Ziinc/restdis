defmodule SupaCacherServer.Rewarm do
  @moduledoc """
  Public API for scheduling and cancelling rewarms of cache keys.
  """

  alias Restdis.Cache.Key
  alias SupaCacherServer.PolicyStore
  alias SupaCacherServer.Rewarm.Scheduler

  @registry SupaCacherServer.Rewarm.Registry
  @dynamic_sup SupaCacherServer.Rewarm.DynamicSupervisor

  @doc """
  Records a read of `wire_key` so its rewarm interval is tracked.
  """
  @spec touch(String.t(), binary(), Key.t()) :: :ok
  def touch(tenant_id, wire_key, %Key{} = key) do
    policy = PolicyStore.get(tenant_id, wire_key)

    if is_nil(policy.rewarm_s) do
      :ok
    else
      with {:ok, pid} <- ensure_scheduler(tenant_id) do
        Scheduler.upsert(pid, wire_key, key, policy)

        :telemetry.execute(
          [:supa_cacher_server, :rewarm, :touch],
          %{count: 1},
          %{tenant_id: tenant_id}
        )
      end

      :ok
    end
  end

  @doc """
  Applies a policy change to the tenant scheduler, starting or clearing rewarms.
  """
  @spec policy_changed(String.t(), binary(), Key.t(), map()) :: :ok
  def policy_changed(tenant_id, wire_key, %Key{} = key, new_policy) do
    if is_nil(new_policy.rewarm_s) do
      case lookup(tenant_id) do
        {:ok, pid} -> Scheduler.policy_changed(pid, wire_key, key, new_policy)
        :error -> :ok
      end
    else
      with {:ok, pid} <- ensure_scheduler(tenant_id) do
        Scheduler.policy_changed(pid, wire_key, key, new_policy)
      end

      :ok
    end
  end

  @doc """
  Stops the rewarm scheduler of `tenant_id`.
  """
  @spec stop_tenant(String.t()) :: :ok
  def stop_tenant(tenant_id) do
    case lookup(tenant_id) do
      {:ok, pid} -> DynamicSupervisor.terminate_child(@dynamic_sup, pid)
      :error -> :ok
    end

    :ok
  end

  defp lookup(tenant_id) do
    case Registry.lookup(@registry, tenant_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  rescue
    _ -> :error
  end

  defp ensure_scheduler(tenant_id) do
    case lookup(tenant_id) do
      {:ok, _} = ok ->
        ok

      :error ->
        case DynamicSupervisor.start_child(@dynamic_sup, {Scheduler, tenant_id: tenant_id}) do
          {:ok, pid} ->
            {:ok, pid}

          {:error, {:already_started, pid}} ->
            {:ok, pid}

          {:error, _} ->
            :error
        end
    end
  rescue
    _ -> :error
  end
end
