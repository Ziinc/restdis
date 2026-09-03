defmodule RestdisElectric.Limits do
  @moduledoc """
  Per-tenant limits on the number of active shapes, the bytes a single
  shape's log may use, and the number of clients waiting on a live read.

  A tenant's limits are cached here (via `put_config/2`) from its tenant
  config at subscribe time, so callers that only ever see a `tenant_id` —
  `RestdisElectric.WAL` and the shape log — can check a limit without the
  full tenant config threaded through every call. A tenant with no cached
  config, or a `nil` value for a given limit, is unlimited for that check.

  Every check returns a distinct `{:limit_exceeded, kind, configured_limit}`
  domain value; naming an HTTP status code for it is the host adapter's job,
  not this module's.
  """

  use GenServer

  alias RestdisElectric.ShapeRegistry

  @table __MODULE__
  @waiting __MODULE__.Waiting

  @type limit_kind :: :shapes | :log_bytes | :waiting_clients
  @type limit_error :: {:limit_exceeded, limit_kind(), pos_integer()}
  @type config :: %{
          max_shapes: pos_integer() | nil,
          max_log_bytes: pos_integer() | nil,
          max_waiting_clients: pos_integer() | nil,
          max_log_operations: pos_integer() | nil
        }

  @default_config %{
    max_shapes: nil,
    max_log_bytes: nil,
    max_waiting_clients: nil,
    max_log_operations: nil
  }

  @doc """
  Starts the limits registry's ETS tables.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Caches `tenant_id`'s limits, read from its tenant config.
  """
  @spec put_config(String.t(), map()) :: :ok
  def put_config(tenant_id, tenant_config) do
    config = %{
      max_shapes: tenant_config[:max_shapes],
      max_log_bytes: tenant_config[:max_log_bytes],
      max_waiting_clients: tenant_config[:max_waiting_clients],
      max_log_operations: tenant_config[:max_log_operations]
    }

    :ets.insert(@table, {tenant_id, config})
    :ok
  end

  @doc """
  Returns `tenant_id`'s cached limits, or all-unlimited if none were cached.
  """
  @spec config(String.t()) :: config()
  def config(tenant_id) do
    if :ets.whereis(@table) == :undefined do
      @default_config
    else
      case :ets.lookup(@table, tenant_id) do
        [{_key, config}] -> config
        [] -> @default_config
      end
    end
  end

  @doc """
  Checks whether `tenant_id` may register one more shape, based on its
  currently registered shape count.
  """
  @spec check_shapes(String.t()) :: :ok | {:error, limit_error()}
  def check_shapes(tenant_id) do
    case config(tenant_id).max_shapes do
      nil -> :ok
      limit -> bounded(ShapeRegistry.count(tenant_id) >= limit, :shapes, limit)
    end
  end

  @doc """
  Checks whether appending `additional_bytes` to a log already holding
  `current_bytes` stays within `tenant_id`'s configured log byte budget.
  """
  @spec check_log_bytes(String.t(), non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, limit_error()}
  def check_log_bytes(tenant_id, current_bytes, additional_bytes) do
    case config(tenant_id).max_log_bytes do
      nil -> :ok
      limit -> bounded(current_bytes + additional_bytes > limit, :log_bytes, limit)
    end
  end

  @doc """
  Returns how many recent operations `handle`'s log should retain: the
  shape's own `retention` (set at subscribe time via its `Definition`) if it
  has one, otherwise `tenant_id`'s configured `max_log_operations` default,
  otherwise `nil` for unlimited.
  """
  @spec effective_retention(String.t(), String.t()) :: pos_integer() | nil
  def effective_retention(tenant_id, handle) do
    case ShapeRegistry.fetch(tenant_id, handle) do
      {:ok, %{retention: retention}} when is_integer(retention) -> retention
      _ -> config(tenant_id).max_log_operations
    end
  end

  @doc """
  Reserves one waiting-client slot for `tenant_id`, rejecting the request if
  that would exceed the configured limit. Every successful call must be
  paired with `exit_wait/1`.
  """
  @spec enter_wait(String.t()) :: :ok | {:error, limit_error()}
  def enter_wait(tenant_id) do
    case config(tenant_id).max_waiting_clients do
      nil ->
        :ok

      limit ->
        count = :ets.update_counter(@waiting, tenant_id, {2, 1}, {tenant_id, 0})

        if count > limit do
          :ets.update_counter(@waiting, tenant_id, {2, -1}, {tenant_id, 0})
          {:error, {:limit_exceeded, :waiting_clients, limit}}
        else
          :ok
        end
    end
  end

  @doc """
  Releases a waiting-client slot reserved by `enter_wait/1`.
  """
  @spec exit_wait(String.t()) :: :ok
  def exit_wait(tenant_id) do
    case config(tenant_id).max_waiting_clients do
      nil -> :ok
      _limit -> release(tenant_id)
    end
  end

  defp release(tenant_id) do
    :ets.update_counter(@waiting, tenant_id, {2, -1}, {tenant_id, 0})
    :ok
  end

  defp bounded(true, kind, limit), do: {:error, {:limit_exceeded, kind, limit}}
  defp bounded(false, _kind, _limit), do: :ok

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    :ets.new(@waiting, [:set, :public, :named_table, write_concurrency: true])
    {:ok, %{}}
  end
end
