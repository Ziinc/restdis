defmodule RestdisElectric.SnapshotDescriptor do
  @moduledoc """
  The descriptor of a direct-Postgres snapshot, `pg_current_snapshot()`'s
  `xmin`, `xmax` and `xip_list`, and the decision it drives: whether a
  buffered transaction's rows are already visible in the snapshot and can be
  skipped when replaying the log, or must be logged.

  A transaction below `xmin` committed before the snapshot was taken and is
  visible. A transaction at or above `xmax` had not yet been assigned an
  identifier when the snapshot was taken and is not visible. A transaction
  between the two is visible only if its identifier is absent from
  `xip_list`, the identifiers still in progress at snapshot time.

  Once a transaction unambiguously started after the snapshot (`xid >=
  xmax`) has been logged, every later transaction is unambiguously after it
  too, so a shape's cursor stops comparing identifiers entirely. This also
  sidesteps 32-bit transaction identifier wraparound, which would otherwise
  make a much later identifier look smaller than `xmin`.
  """

  @type xid :: non_neg_integer()

  @type t :: %{xmin: xid(), xmax: xid(), xip_list: [xid()]}

  @type decision :: :skip | :log

  @opaque cursor :: {:comparing, t()} | :always_log

  @doc """
  Parses the text form of `pg_current_snapshot()`, `"xmin:xmax:xip1,xip2"`.
  """
  @spec parse(String.t()) :: {:ok, t()} | :error
  def parse(text) when is_binary(text) do
    case String.split(text, ":", parts: 3) do
      [xmin_str, xmax_str, xip_str] -> parse_parts(xmin_str, xmax_str, xip_str)
      _ -> :error
    end
  end

  def parse(_), do: :error

  defp parse_parts(xmin_str, xmax_str, xip_str) do
    with {xmin, ""} <- Integer.parse(xmin_str),
         {xmax, ""} <- Integer.parse(xmax_str),
         {:ok, xip_list} <- parse_xip_list(xip_str) do
      {:ok, %{xmin: xmin, xmax: xmax, xip_list: xip_list}}
    else
      _ -> :error
    end
  end

  defp parse_xip_list(""), do: {:ok, []}

  defp parse_xip_list(xip_str) do
    xip_str
    |> String.split(",")
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, acc} ->
      case Integer.parse(part) do
        {xid, ""} -> {:cont, {:ok, [xid | acc]}}
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  @doc """
  Encodes `descriptor` back into `pg_current_snapshot()`'s text form,
  `"xmin:xmax:xip1,xip2"`, the inverse of `parse/1`.
  """
  @spec to_string(t()) :: String.t()
  def to_string(%{xmin: xmin, xmax: xmax, xip_list: xip_list}) do
    "#{xmin}:#{xmax}:#{Enum.join(xip_list, ",")}"
  end

  @doc """
  Returns true when `xid` is visible in `descriptor` — already committed as
  of the snapshot, so a buffered transaction with this identifier is already
  represented in the snapshot rows.
  """
  @spec visible?(t(), xid()) :: boolean()
  def visible?(%{xmin: xmin, xmax: xmax, xip_list: xip_list}, xid) do
    cond do
      xid < xmin -> true
      xid >= xmax -> false
      true -> xid not in xip_list
    end
  end

  @doc """
  Builds a cursor that starts out comparing identifiers against `descriptor`.
  """
  @spec new_cursor(t()) :: cursor()
  def new_cursor(%{} = descriptor), do: {:comparing, descriptor}

  @doc """
  Decides whether the buffered transaction identified by `xid` was already
  applied by the snapshot (`:skip`) or must be logged (`:log`), and returns
  the cursor to use for the next decision.
  """
  @spec decide(cursor(), xid()) :: {decision(), cursor()}
  def decide(:always_log, _xid), do: {:log, :always_log}

  def decide({:comparing, descriptor}, xid) do
    if visible?(descriptor, xid) do
      {:skip, {:comparing, descriptor}}
    else
      if xid >= descriptor.xmax do
        {:log, :always_log}
      else
        {:log, {:comparing, descriptor}}
      end
    end
  end

  @doc """
  Returns true once the cursor has latched into always-log and stopped
  comparing identifiers.
  """
  @spec always_log?(cursor()) :: boolean()
  def always_log?(:always_log), do: true
  def always_log?({:comparing, _descriptor}), do: false
end
