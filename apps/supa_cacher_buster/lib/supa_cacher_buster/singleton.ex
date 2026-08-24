defmodule SupaCacherBuster.Singleton do
  @moduledoc """
  Cluster-wide singleton registration for the `wal_tailer`, backed by `:syn`.
  """

  use GenServer

  require Logger

  @doc """
  Starts the singleton owner process that registers the `wal_tailer`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    send(self(), :try_register)
    {:ok, %{tailer: nil}}
  end

  @impl GenServer
  def handle_info(:try_register, state) do
    case :syn.register(:wal, :wal_tailer, self()) do
      :ok ->
        :telemetry.execute(
          [:supa_cacher_buster, :singleton, :owner],
          %{is_owner: 1},
          %{node: node()}
        )

        case start_tailer() do
          {:ok, pid} ->
            Process.monitor(pid)
            Logger.info("[SupaCacherBuster] This node is the WAL tailer singleton")
            {:noreply, %{state | tailer: pid}}

          {:error, reason} ->
            Logger.warning(
              "[SupaCacherBuster] Failed to start Tailer: #{inspect(reason)}, retrying in 2s"
            )

            :syn.unregister(:wal, :wal_tailer)
            Process.send_after(self(), :try_register, 2_000)
            {:noreply, state}
        end

      {:error, :taken} ->
        :telemetry.execute(
          [:supa_cacher_buster, :singleton, :owner],
          %{is_owner: 0},
          %{node: node()}
        )

        monitor_winner()
        {:noreply, state}

      {:error, _reason} ->
        Process.send_after(self(), :try_register, 1_000)
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, %{tailer: pid} = state) do
    # Our own Tailer died
    Logger.warning("[SupaCacherBuster] Tailer crashed (#{inspect(reason)}), restarting")
    :syn.unregister(:wal, :wal_tailer)

    :telemetry.execute(
      [:supa_cacher_buster, :singleton, :owner],
      %{is_owner: 0},
      %{node: node()}
    )

    send(self(), :try_register)
    {:noreply, %{state | tailer: nil}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    # Remote winner died — race to become the new one
    Logger.info("[SupaCacherBuster] WAL tailer singleton went down, attempting takeover")
    send(self(), :try_register)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp start_tailer do
    DynamicSupervisor.start_child(
      SupaCacherBuster.TailerSupervisor,
      {SupaCacherBuster.Tailer, []}
    )
  end

  defp monitor_winner do
    case :syn.lookup(:wal, :wal_tailer) do
      :undefined ->
        # May have just died; retry immediately
        send(self(), :try_register)

      {pid, _meta} when is_pid(pid) ->
        Process.monitor(pid)
    end
  end
end
