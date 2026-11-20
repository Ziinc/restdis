defmodule Restdis.Wal.Singleton do
  @moduledoc """
  Cluster-wide singleton registration for the `wal_tailer`, backed by `:syn`.
  """

  use GenServer

  require Logger

  alias Restdis.Wal.InstanceConfig
  alias Restdis.Wal.Tailer

  @doc """
  Starts the singleton owner process that registers the `wal_tailer`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, name, name: Module.concat(name, Singleton))
  end

  @doc """
  Runs the instance's `on_takeover` callback, which closes the WAL gap of this takeover.
  """
  @spec notify_ownership_acquired(atom()) :: :ok
  def notify_ownership_acquired(name) do
    case InstanceConfig.fetch!(name).on_takeover do
      nil -> :ok
      {module, function, args} -> apply(module, function, args)
    end

    :ok
  end

  @impl GenServer
  def init(name) do
    send(self(), :try_register)
    {:ok, %{name: name, tailer: nil}}
  end

  @impl GenServer
  def handle_info(:try_register, state) do
    case :syn.register(:wal, {state.name, :wal_tailer}, self()) do
      :ok ->
        :telemetry.execute(
          telemetry_prefix(state) ++ [:singleton, :owner],
          %{is_owner: 1},
          %{node: node()}
        )

        case start_tailer(state.name) do
          {:ok, pid} ->
            Process.monitor(pid)
            Logger.info("[Restdis.Wal] This node is the WAL tailer singleton")
            notify_ownership_acquired(state.name)
            {:noreply, %{state | tailer: pid}}

          {:error, reason} ->
            Logger.warning(
              "[Restdis.Wal] Failed to start Tailer: #{inspect(reason)}, retrying in 2s"
            )

            :syn.unregister(:wal, {state.name, :wal_tailer})
            Process.send_after(self(), :try_register, 2_000)
            {:noreply, state}
        end

      {:error, :taken} ->
        :telemetry.execute(
          telemetry_prefix(state) ++ [:singleton, :owner],
          %{is_owner: 0},
          %{node: node()}
        )

        monitor_winner(state.name)
        {:noreply, state}

      {:error, _reason} ->
        Process.send_after(self(), :try_register, 1_000)
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, %{tailer: pid} = state) do
    # Our own Tailer died
    Logger.warning("[Restdis.Wal] Tailer crashed (#{inspect(reason)}), restarting")
    :syn.unregister(:wal, {state.name, :wal_tailer})

    :telemetry.execute(
      telemetry_prefix(state) ++ [:singleton, :owner],
      %{is_owner: 0},
      %{node: node()}
    )

    send(self(), :try_register)
    {:noreply, %{state | tailer: nil}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    # Remote winner died — race to become the new one
    Logger.info("[Restdis.Wal] WAL tailer singleton went down, attempting takeover")
    send(self(), :try_register)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp telemetry_prefix(state), do: InstanceConfig.fetch!(state.name).telemetry_prefix

  defp start_tailer(name) do
    DynamicSupervisor.start_child(Module.concat(name, TailerSupervisor), {Tailer, name: name})
  end

  defp monitor_winner(name) do
    case :syn.lookup(:wal, {name, :wal_tailer}) do
      :undefined ->
        # May have just died; retry immediately
        send(self(), :try_register)

      {pid, _meta} when is_pid(pid) ->
        Process.monitor(pid)
    end
  end
end
