defmodule SupaCacherCache.Replication do
  @moduledoc """
  Global disk cache replication for `persist` entries (PRD Phase 4, step 6).

  Writes flagged `persist` are broadcast to peer nodes, which apply them to
  their own disk cache and reverse index. Replicated writes are applied with
  `replicated: true` so a peer never re-broadcasts, which bounds every event to
  a single hop.

  Replication is async and best-effort: a peer that misses an event keeps
  serving from its own layers until the next write for that key.
  """

  alias SupaCacherCache.Key

  @type event ::
          {:put, Key.t(), term(), keyword()}
          | {:delete, Key.t()}
          | {:set_persist, Key.t(), boolean()}

  @wire_opts [:persist, :persist_cap, :ttl_ms, :pk_column, :primary_keys]

  @doc """
  Sends `event` to every peer node. A no-op when no transport is configured.
  """
  @spec broadcast(SupaCacherCache.tenant_id(), event()) :: :ok
  def broadcast(tenant_id, event) do
    case transport() do
      nil ->
        :ok

      transport ->
        message = {:sc_replication, tenant_id, sanitize(event)}
        :ok = transport.broadcast(message)

        :telemetry.execute([:supa_cacher_cache, :replication, :broadcast], %{count: 1}, %{
          tenant_id: tenant_id,
          op: elem(event, 0)
        })

        :ok
    end
  end

  @doc """
  Applies a peer's `event` to the local cache layers without re-broadcasting it.
  """
  @spec apply_event(SupaCacherCache.tenant_id(), event()) ::
          :ok | {:error, :persist_cap | :not_found}
  def apply_event(tenant_id, event) do
    result = do_apply(tenant_id, event)
    op = elem(event, 0)

    case result do
      :ok ->
        :telemetry.execute([:supa_cacher_cache, :replication, :applied], %{count: 1}, %{
          tenant_id: tenant_id,
          op: op
        })

      {:error, reason} ->
        :telemetry.execute([:supa_cacher_cache, :replication, :rejected], %{count: 1}, %{
          tenant_id: tenant_id,
          op: op,
          reason: reason
        })
    end

    result
  end

  defp do_apply(tenant_id, {:put, key, value, opts}) do
    SupaCacherCache.put(tenant_id, key, value, Keyword.put(opts, :replicated, true))
  end

  defp do_apply(tenant_id, {:delete, key}) do
    SupaCacherCache.delete(tenant_id, key, replicated: true)
  end

  defp do_apply(tenant_id, {:set_persist, key, persist}) do
    SupaCacherCache.set_persist(tenant_id, key, persist, replicated: true)
  end

  defp sanitize({:put, key, value, opts}) do
    {:put, key, value, Keyword.take(opts, @wire_opts)}
  end

  defp sanitize(event), do: event

  defp transport do
    Application.get_env(
      :supa_cacher_cache,
      :replication_transport,
      SupaCacherCache.Replication.Transport.Distribution
    )
  end
end
