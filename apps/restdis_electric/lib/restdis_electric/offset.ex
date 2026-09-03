defmodule RestdisElectric.Offset do
  @moduledoc """
  Encoding, decoding and ordering of shape log offsets.

  The wire forms are `-1` (before the snapshot), `0_inf` (the end of the
  snapshot), `now` (skip all history) and `{lsn}_{op_offset}`. The LSN crosses
  the context boundary as a plain integer, so this module has no dependency on
  the WAL reader's own LSN representation.

  Internally an offset is `:beginning`, `:now`, or a `{lsn, op_offset}` tuple
  where `op_offset` is a non-negative integer or `:inf`. Erlang term ordering
  over those tuples is the log ordering: integers sort before atoms, so
  `{0, 5} < {0, :inf} < {1, 0}`.
  """

  @type op_offset :: non_neg_integer() | :inf
  @type position :: {non_neg_integer(), op_offset()}
  @type t :: :beginning | :now | position()

  @beginning :beginning
  @snapshot_end {0, :inf}

  @doc """
  The offset before any operation, encoded as `-1`.
  """
  @spec beginning() :: t()
  def beginning, do: @beginning

  @doc """
  The offset marking the end of the snapshot, encoded as `0_inf`.
  """
  @spec snapshot_end() :: t()
  def snapshot_end, do: @snapshot_end

  @doc """
  Decodes a wire offset.
  """
  @spec decode(String.t() | nil) :: {:ok, t()} | :error
  def decode(nil), do: :error
  def decode("-1"), do: {:ok, @beginning}
  def decode("now"), do: {:ok, :now}
  def decode("0_inf"), do: {:ok, @snapshot_end}

  def decode(binary) when is_binary(binary) do
    case String.split(binary, "_", parts: 2) do
      [lsn_str, op_str] -> decode_parts(lsn_str, op_str)
      _ -> :error
    end
  end

  def decode(_), do: :error

  @doc """
  Encodes an offset into its wire form.
  """
  @spec encode(t()) :: String.t()
  def encode(@beginning), do: "-1"
  def encode(:now), do: "now"
  def encode({lsn, :inf}), do: "#{lsn}_inf"
  def encode({lsn, op}) when is_integer(op), do: "#{lsn}_#{op}"

  @doc """
  Returns true when `a` sorts strictly before `b`.
  """
  @spec before?(t(), t()) :: boolean()
  def before?(a, b), do: rank(a) < rank(b)

  @doc """
  Returns true when `a` and `b` denote the same position.
  """
  @spec equal?(t(), t()) :: boolean()
  def equal?(a, b), do: rank(a) == rank(b)

  @doc """
  Returns the later of two offsets.
  """
  @spec max(t(), t()) :: t()
  def max(a, b), do: if(before?(a, b), do: b, else: a)

  @doc """
  Returns true when the offset denotes a position inside the snapshot.
  """
  @spec snapshot?(t()) :: boolean()
  def snapshot?({0, _}), do: true
  def snapshot?(_), do: false

  # `:beginning` sorts before every position; `:now` sorts after every position.
  defp rank(@beginning), do: {0, 0, 0}
  defp rank(:now), do: {2, 0, 0}
  defp rank({lsn, :inf}), do: {1, lsn, :inf}
  defp rank({lsn, op}) when is_integer(op), do: {1, lsn, op}

  defp decode_parts(lsn_str, op_str) do
    with {lsn, ""} <- Integer.parse(lsn_str),
         true <- lsn >= 0,
         {:ok, op} <- decode_op(op_str) do
      {:ok, {lsn, op}}
    else
      _ -> :error
    end
  end

  defp decode_op("inf"), do: {:ok, :inf}

  defp decode_op(op_str) do
    case Integer.parse(op_str) do
      {op, ""} when op >= 0 -> {:ok, op}
      _ -> :error
    end
  end
end
