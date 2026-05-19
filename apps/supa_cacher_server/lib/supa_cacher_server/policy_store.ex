defmodule SupaCacherServer.PolicyStore do
  use GenServer

  @table :supa_cacher_policy_store

  @type policy :: %{rewarm_s: pos_integer() | nil, persist: boolean()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec get(String.t(), String.t()) :: policy()
  def get(tenant_id, wire_key) do
    case :ets.lookup(@table, {tenant_id, wire_key}) do
      [{_, policy}] -> policy
      [] -> %{rewarm_s: nil, persist: false}
    end
  end

  @spec put(String.t(), String.t(), policy()) :: :ok
  def put(tenant_id, wire_key, policy) do
    :ets.insert(@table, {{tenant_id, wire_key}, policy})
    :ok
  end

  @spec delete(String.t(), String.t()) :: :ok
  def delete(tenant_id, wire_key) do
    :ets.delete(@table, {tenant_id, wire_key})
    :ok
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true, write_concurrency: true])
    {:ok, %{}}
  end
end
