defmodule SupaCacherBuster.Infra.LSN do
  @moduledoc false

  # Microseconds from PostgreSQL epoch (2000-01-01 00:00:00 UTC)
  @pg_epoch DateTime.to_unix(~U[2000-01-01 00:00:00Z], :microsecond)

  @doc """
  Builds a standby status update frame acknowledging the given LSNs.
  """
  @spec standby_status(non_neg_integer(), non_neg_integer()) :: binary()
  def standby_status(stream_wal_end, applied_lsn) do
    clock = System.os_time(:microsecond) - @pg_epoch
    written = max(stream_wal_end, applied_lsn) + 1
    flushed_applied = if applied_lsn == 0, do: 1, else: applied_lsn + 1

    <<
      ?r,
      written::64,
      flushed_applied::64,
      flushed_applied::64,
      clock::64,
      0::8
    >>
  end

  @doc """
  Returns the current time in microseconds since the PostgreSQL epoch.
  """
  @spec current_clock() :: non_neg_integer()
  def current_clock do
    System.os_time(:microsecond) - @pg_epoch
  end
end
