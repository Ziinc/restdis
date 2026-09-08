defmodule Restdis.Cache.Router do
  @moduledoc """
  Routes cache operations to the node owning the tenant (PRD Phase 6, steps 3 and 7).

  The owner serves the request locally. Any other node forwards it over Erlang
  distribution with a one second budget; when the owner is unreachable within
  that budget the caller gets `{:error, :unreachable}` and falls back to
  fetching from PostgREST itself.
  """

  alias Restdis.Cache.Cluster
  alias Restdis.Cache.HotCache
  alias Restdis.Cache.Key

  @timeout_ms 1_000

  @type unreachable :: {:error, :unreachable}

  @doc """
  Returns the node owning `tenant_id`.
  """
  @spec owner(Restdis.Cache.tenant_id()) :: node()
  def owner(tenant_id), do: Cluster.owner(tenant_id)

  @doc """
  Routed `Restdis.Cache.get/2`.

  Checked against the cluster-wide `Restdis.Cache.HotCache` layer first: a
  hit there is served with no cross-node hop at all, whichever node owns
  the tenant. A miss falls through to the owner-routed cache as before, and
  a hit obtained that way is recorded so the key can turn hot and get
  gossiped to every peer.
  """
  @spec get(Restdis.Cache.tenant_id(), Key.t()) :: {:ok, term()} | :miss | unreachable()
  def get(tenant_id, key) do
    case HotCache.get(tenant_id, key) do
      {:ok, value} ->
        {:ok, value}

      :miss ->
        case route(tenant_id, :get, [tenant_id, key]) do
          {:ok, value} = result ->
            HotCache.observe(tenant_id, key, value)
            result

          other ->
            other
        end
    end
  end

  @doc """
  Routed `Restdis.Cache.peek/2`.
  """
  @spec peek(Restdis.Cache.tenant_id(), Key.t()) :: {:ok, term()} | :miss | unreachable()
  def peek(tenant_id, key), do: route(tenant_id, :peek, [tenant_id, key])

  @doc """
  Routed `Restdis.Cache.put/4`.
  """
  @spec put(Restdis.Cache.tenant_id(), Key.t(), term(), keyword()) ::
          :ok | {:error, :persist_cap} | unreachable()
  def put(tenant_id, key, value, opts \\ []),
    do: route(tenant_id, :put, [tenant_id, key, value, opts])

  @doc """
  Routed `Restdis.Cache.delete/3`.
  """
  @spec delete(Restdis.Cache.tenant_id(), Key.t(), keyword()) :: :ok | unreachable()
  def delete(tenant_id, key, opts \\ []), do: route(tenant_id, :delete, [tenant_id, key, opts])

  defp route(tenant_id, fun, args) do
    owner = Cluster.owner(tenant_id)

    if owner == Node.self() do
      apply(Restdis.Cache, fun, args)
    else
      forward(owner, tenant_id, fun, args)
    end
  end

  defp forward(owner, tenant_id, fun, args) do
    :telemetry.execute([:restdis, :cluster, :forward], %{count: 1}, %{
      tenant_id: tenant_id,
      owner: owner,
      op: fun
    })

    :erpc.call(owner, Restdis.Cache, fun, args, @timeout_ms)
  rescue
    e in ErlangError ->
      case e.original do
        {:erpc, reason} when reason in [:timeout, :noconnection] ->
          unreachable(tenant_id, owner, fun)

        _ ->
          reraise e, __STACKTRACE__
      end
  catch
    :exit, {:erpc, reason} when reason in [:timeout, :noconnection] ->
      unreachable(tenant_id, owner, fun)
  end

  defp unreachable(tenant_id, owner, fun) do
    :telemetry.execute([:restdis, :cluster, :unreachable], %{count: 1}, %{
      tenant_id: tenant_id,
      owner: owner,
      op: fun
    })

    {:error, :unreachable}
  end
end
