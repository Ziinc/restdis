defmodule SupaCacherServer.RESP.Encoder do
  @spec simple_string(binary()) :: iodata()
  def simple_string(str), do: ["+", str, "\r\n"]

  @spec error(binary()) :: iodata()
  def error(msg), do: ["-", msg, "\r\n"]

  @spec integer(integer()) :: iodata()
  def integer(n), do: [":", Integer.to_string(n), "\r\n"]

  @spec bulk_string(binary() | nil) :: iodata()
  def bulk_string(nil), do: "$-1\r\n"

  def bulk_string(bin) do
    ["$", Integer.to_string(byte_size(bin)), "\r\n", bin, "\r\n"]
  end

  @spec array(list()) :: iodata()
  def array(items) do
    encoded = Enum.map(items, &encode_item/1)
    ["*", Integer.to_string(length(items)), "\r\n" | encoded]
  end

  defp encode_item(nil), do: bulk_string(nil)
  defp encode_item(n) when is_integer(n), do: integer(n)
  defp encode_item(bin) when is_binary(bin), do: bulk_string(bin)
end
