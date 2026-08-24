defmodule SupaCacherServer.PolicyStore do
  @moduledoc """
  Per-tenant store of rewarm and persist policy for cache keys.
  """

  use GenServer

  @table :supa_cacher_policy_store

  @type policy :: %{rewarm_s: pos_integer() | nil, persist: boolean()}

  @doc """
  Starts the policy store and its ETS table.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the policy of `wire_key`, or the default policy when unset.
  """
  @spec get(String.t(), String.t()) :: policy()
  def get(tenant_id, wire_key) do
    case :ets.lookup(@table, {tenant_id, wire_key}) do
      [{_, policy}] -> policy
      [] -> %{rewarm_s: nil, persist: false}
    end
  end

  @doc """
  Stores the policy of `wire_key`.
  """
  @spec put(String.t(), String.t(), policy()) :: :ok
  def put(tenant_id, wire_key, policy) do
    :ets.insert(@table, {{tenant_id, wire_key}, policy})
    :ok
  end

  @doc """
  Drops the stored policy of `wire_key`.
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
