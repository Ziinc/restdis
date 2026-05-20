defmodule SupaCacherBuster.Infra.LsnStore do
  @moduledoc false

  use GenServer

  require Logger

  alias SupaCacherBuster.Infra.SlotConfig

  @persist_interval_ms 1_000
  @table "wal_checkpoint"

  # The atomic is module-global so callers (workers, tailers) can read/write
  # without a GenServer hop. The GenServer owns persistence.
  @ref_key {__MODULE__, :ref}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec applied(non_neg_integer() | nil) :: :ok
  def applied(nil), do: :ok
  def applied(lsn) when is_integer(lsn) and lsn >= 0 do
    ref = ref()
    if ref, do: bump(ref, lsn)
    :ok
  end

  @spec current_applied() :: non_neg_integer()
  def current_applied do
    case ref() do
      nil -> 0
      ref -> :atomics.get(ref, 1)
    end
  end

  @spec persisted() :: non_neg_integer()
  def persisted do
    slot = SlotConfig.slot_name()
    read_persisted(slot)
  end

  @impl GenServer
  def init(_opts) do
    ref = :atomics.new(1, signed: false)
    :persistent_term.put(@ref_key, ref)

    slot = SlotConfig.slot_name()
    initial = ensure_row_and_read(slot)
    if initial > 0, do: :atomics.put(ref, 1, initial)

    schedule_persist()
    {:ok, %{slot: slot, ref: ref, last_persisted: initial}}
  end

  @impl GenServer
  def handle_info(:persist, %{ref: ref, last_persisted: last} = state) do
    current = :atomics.get(ref, 1)

    new_last =
      if current > last do
        case write_persisted(state.slot, current) do
          :ok -> current
          :error -> last
        end
      else
        last
      end

    schedule_persist()
    {:noreply, %{state | last_persisted: new_last}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule_persist do
    Process.send_after(self(), :persist, @persist_interval_ms)
  end

  defp bump(ref, new_lsn) do
    current = :atomics.get(ref, 1)

    cond do
      new_lsn <= current ->
        :ok

      :atomics.compare_exchange(ref, 1, current, new_lsn) == :ok ->
        :ok

      true ->
        bump(ref, new_lsn)
    end
  end

  defp ref do
    case :persistent_term.get(@ref_key, nil) do
      nil -> nil
      ref -> ref
    end
  end

  defp ensure_row_and_read(slot) do
    try do
      repo = SupaCacherRepo
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      Ecto.Adapters.SQL.query!(
        repo,
        "INSERT INTO #{@table} (slot_name, lsn, inserted_at, updated_at) VALUES ($1, 0, $2, $2) ON CONFLICT (slot_name) DO NOTHING",
        [slot, now]
      )

      read_persisted(slot)
    rescue
      e ->
        Logger.warning("LsnStore: degraded mode (DB unavailable): #{Exception.message(e)}")
        0
    catch
      kind, reason ->
        Logger.warning("LsnStore: degraded mode (#{kind}): #{inspect(reason)}")
        0
    end
  end

  defp read_persisted(slot) do
    try do
      %{rows: rows} =
        Ecto.Adapters.SQL.query!(
          SupaCacherRepo,
          "SELECT lsn FROM #{@table} WHERE slot_name = $1",
          [slot]
        )

      case rows do
        [[lsn]] when is_integer(lsn) -> lsn
        _ -> 0
      end
    rescue
      _ -> 0
    catch
      _, _ -> 0
    end
  end

  defp write_persisted(slot, lsn) do
    try do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      Ecto.Adapters.SQL.query!(
        SupaCacherRepo,
        "UPDATE #{@table} SET lsn = $1, updated_at = $2 WHERE slot_name = $3",
        [lsn, now, slot]
      )

      :ok
    rescue
      e ->
        Logger.warning("LsnStore: persist failed: #{Exception.message(e)}")
        :error
    catch
      _, _ -> :error
    end
  end
end
