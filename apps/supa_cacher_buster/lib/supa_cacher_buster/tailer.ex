defmodule SupaCacherBuster.Tailer do
  use Postgrex.ReplicationConnection

  alias SupaCacherBuster.Dispatcher
  alias SupaCacherBuster.Infra.LSN
  alias SupaCacherBuster.Infra.LsnStore
  alias SupaCacherBuster.Infra.SlotConfig
  alias SupaCacherBuster.WAL.Pgoutput
  alias SupaCacherBuster.WAL.RelationCache

  @type state :: %{
          step: :create_slot | :streaming,
          decode_state: {RelationCache.t(), non_neg_integer() | nil},
          last_wal_end: non_neg_integer()
        }

  def start_link(opts \\ []) do
    conn_opts =
      SlotConfig.replication_conn_opts()
      |> Keyword.put_new(:auto_reconnect, true)
      |> Keyword.merge(opts)

    Postgrex.ReplicationConnection.start_link(__MODULE__, :ok, conn_opts)
  end

  @impl true
  def init(:ok) do
    state = %{
      step: :create_slot,
      decode_state: {RelationCache.new(), nil},
      last_wal_end: 0
    }

    {:ok, state}
  end

  @impl true
  def handle_connect(state) do
    slot = SlotConfig.slot_name()
    query = "CREATE_REPLICATION_SLOT #{slot} LOGICAL pgoutput NOEXPORT_SNAPSHOT"
    {:query, query, %{state | step: :create_slot}}
  end

  @impl true
  def handle_result([_result], %{step: :create_slot} = state) do
    stream(state)
  end

  def handle_result(
        %Postgrex.Error{postgres: %{code: :duplicate_object}},
        %{step: :create_slot} = state
      ) do
    stream(state)
  end

  def handle_result(_result, state) do
    {:noreply, state}
  end

  @impl true
  # XLogData: WAL record
  def handle_data(<<?w, _wal_start::64, wal_end::64, _clock::64, rest::binary>>, state) do
    :telemetry.execute(
      [:supa_cacher_buster, :wal, :received],
      %{bytes: byte_size(rest), count: 1},
      %{wal_end: wal_end}
    )

    {events, new_decode_state} = Pgoutput.decode(rest, state.decode_state)

    :telemetry.execute(
      [:supa_cacher_buster, :wal, :decoded],
      %{count: length(events)},
      %{}
    )

    Enum.each(events, &Dispatcher.dispatch/1)

    new_state = %{
      state
      | decode_state: new_decode_state,
        last_wal_end: max(state.last_wal_end, wal_end)
    }

    {:noreply, new_state}
  end

  # Primary keepalive
  def handle_data(<<?k, wal_end::64, clock::64, reply::8>>, state) do
    :telemetry.execute(
      [:supa_cacher_buster, :tailer, :lag],
      %{lag_us: LSN.current_clock() - clock},
      %{wal_end: wal_end}
    )

    new_wal_end = max(state.last_wal_end, wal_end)

    messages =
      if reply == 1 do
        [LSN.standby_status(new_wal_end, LsnStore.current_applied())]
      else
        []
      end

    {:noreply, messages, %{state | last_wal_end: new_wal_end}}
  end

  def handle_data(_data, state), do: {:noreply, state}

  defp stream(state) do
    slot = SlotConfig.slot_name()
    pub = SlotConfig.publication_name()
    start_lsn = format_lsn(LsnStore.persisted())

    query =
      "START_REPLICATION SLOT #{slot} LOGICAL #{start_lsn} (proto_version '1', publication_names '#{pub}')"

    {:stream, query, [], %{state | step: :streaming}}
  end

  defp format_lsn(lsn) when is_integer(lsn) and lsn >= 0 do
    high = Bitwise.bsr(lsn, 32)
    low = Bitwise.band(lsn, 0xFFFFFFFF)
    "#{Integer.to_string(high, 16)}/#{Integer.to_string(low, 16)}"
  end
end
