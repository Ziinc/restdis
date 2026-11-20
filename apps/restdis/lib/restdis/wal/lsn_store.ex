defmodule Restdis.Wal.LsnStore do
  @moduledoc false

  use GenServer

  require Logger

  alias Ecto.Adapters.SQL
  alias Restdis.Migrations.SqlQuoting
  alias Restdis.Wal.InstanceConfig

  @persist_interval_ms 1_000

  @doc """
  Starts the LSN store of the instance `opts[:name]`, which owns the atomic holding its applied LSN.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, name, name: Module.concat(name, LsnStore))
  end

  @doc """
  Records `lsn` as applied by the instance `name`. A `nil` LSN is ignored.
  """
  @spec applied(atom(), non_neg_integer() | nil) :: :ok
  def applied(_name, nil), do: :ok

  def applied(name, lsn) when is_integer(lsn) and lsn >= 0 do
    ref = ref(name)
    if ref, do: bump(ref, lsn)
    :ok
  end

  @doc """
  Returns the LSN applied so far by the instance `name`, or `0` when its store is not running.
  """
  @spec current_applied(atom()) :: non_neg_integer()
  def current_applied(name) do
    case ref(name) do
      nil -> 0
      ref -> :atomics.get(ref, 1)
    end
  end

  @doc """
  Reads the LSN last persisted to the checkpoint table for the instance `name`.
  """
  @spec persisted(atom()) :: non_neg_integer()
  def persisted(name) do
    read_persisted(InstanceConfig.fetch!(name))
  end

  @impl GenServer
  def init(name) do
    ref = :atomics.new(1, signed: false)
    :persistent_term.put({__MODULE__, name}, ref)

    config = InstanceConfig.fetch!(name)
    initial = ensure_row_and_read(config)
    if initial > 0, do: :atomics.put(ref, 1, initial)

    schedule_persist()
    {:ok, %{config: config, ref: ref, last_persisted: initial}}
  end

  @impl GenServer
  def handle_info(:persist, %{ref: ref, last_persisted: last} = state) do
    current = :atomics.get(ref, 1)

    new_last =
      if current > last do
        case write_persisted(state.config, current) do
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

  defp ref(name) do
    :persistent_term.get({__MODULE__, name}, nil)
  end

  defp table(%{prefix: prefix}), do: "#{SqlQuoting.quote_ident(prefix)}.wal_checkpoint"

  defp ensure_row_and_read(config) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    SQL.query!(
      config.repo,
      "INSERT INTO #{table(config)} (slot_name, lsn, inserted_at, updated_at) VALUES ($1, 0, $2, $2) ON CONFLICT (slot_name) DO NOTHING",
      [config.slot_name, now]
    )

    read_persisted(config)
  rescue
    e ->
      Logger.warning("LsnStore: degraded mode (DB unavailable): #{Exception.message(e)}")
      0
  catch
    kind, reason ->
      Logger.warning("LsnStore: degraded mode (#{kind}): #{inspect(reason)}")
      0
  end

  defp read_persisted(config) do
    %{rows: rows} =
      SQL.query!(
        config.repo,
        "SELECT lsn FROM #{table(config)} WHERE slot_name = $1",
        [config.slot_name]
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

  defp write_persisted(config, lsn) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    SQL.query!(
      config.repo,
      "UPDATE #{table(config)} SET lsn = $1, updated_at = $2 WHERE slot_name = $3",
      [lsn, now, config.slot_name]
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
