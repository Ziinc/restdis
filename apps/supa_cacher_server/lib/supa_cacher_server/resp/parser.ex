defmodule SupaCacherServer.RESP.Parser do
  @type command :: [binary() | nil]

  @type parse_result ::
          {:ok, command(), rest :: binary()}
          | {:more, rest :: binary()}
          | {:error, reason :: term()}

  # Returns {:more, original_data} when the buffer is incomplete so callers
  # can safely append more bytes and retry without losing prefix bytes.
  @spec parse(binary()) :: parse_result()
  def parse(data) do
    case do_parse(data) do
      {:more, _inner} -> {:more, data}
      other -> other
    end
  end

  defp do_parse(<<"*", rest::binary>>) do
    with {:ok, count, rest} <- parse_integer_line(rest),
         {:ok, items, rest} <- parse_bulk_array(count, rest, []) do
      {:ok, items, rest}
    end
  end

  defp do_parse(data) do
    case :binary.split(data, "\r\n") do
      [_] ->
        {:more, data}

      [line, rest] ->
        parts = String.split(line, " ", trim: true)
        {:ok, parts, rest}
    end
  end

  defp parse_bulk_array(0, rest, acc), do: {:ok, Enum.reverse(acc), rest}

  defp parse_bulk_array(n, data, acc) do
    with {:ok, item, rest} <- parse_one_bulk(data) do
      parse_bulk_array(n - 1, rest, [item | acc])
    end
  end

  defp parse_one_bulk(<<"$", rest::binary>>) do
    with {:ok, len, rest} <- parse_integer_line(rest) do
      parse_bulk_bytes(len, rest)
    end
  end

  defp parse_one_bulk(data) when byte_size(data) == 0, do: {:more, data}

  defp parse_one_bulk(_), do: {:error, :expected_bulk_string}

  defp parse_bulk_bytes(-1, rest), do: {:ok, nil, rest}

  defp parse_bulk_bytes(len, data) when len >= 0 do
    needed = len + 2

    if byte_size(data) >= needed do
      <<bulk::binary-size(len), "\r\n", rest::binary>> = data
      {:ok, bulk, rest}
    else
      {:more, data}
    end
  end

  defp parse_integer_line(data) do
    case :binary.split(data, "\r\n") do
      [_] ->
        {:more, data}

      [line, rest] ->
        case Integer.parse(line) do
          {n, ""} -> {:ok, n, rest}
          _ -> {:error, {:bad_integer, line}}
        end
    end
  end
end
