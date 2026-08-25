defmodule RestdisServer.RESP.Encoder do
  @moduledoc """
  Encodes values into the RESP wire format.
  """

  @doc """
  Encodes a RESP simple string.
  """
  @spec simple_string(binary()) :: iodata()
  def simple_string(str), do: ["+", str, "\r\n"]

  @doc """
  Encodes a RESP error.
  """
  @spec error(binary()) :: iodata()
  def error(msg), do: ["-", msg, "\r\n"]

  @doc """
  Encodes a RESP integer.
  """
  @spec integer(integer()) :: iodata()
  def integer(n), do: [":", Integer.to_string(n), "\r\n"]

  @doc """
  Encodes a RESP bulk string; `nil` becomes the null bulk string.
  """
  @spec bulk_string(binary() | nil) :: iodata()
  def bulk_string(nil), do: "$-1\r\n"

  def bulk_string(bin) do
    ["$", Integer.to_string(byte_size(bin)), "\r\n", bin, "\r\n"]
  end

  @doc """
  Encodes a RESP array of bulk strings, integers and nils.
  """
  @spec array(list()) :: iodata()
  def array(items) do
    encoded = Enum.map(items, &encode_item/1)
    ["*", Integer.to_string(length(items)), "\r\n" | encoded]
  end

  defp encode_item(nil), do: bulk_string(nil)
  defp encode_item(n) when is_integer(n), do: integer(n)
  defp encode_item(bin) when is_binary(bin), do: bulk_string(bin)
end
