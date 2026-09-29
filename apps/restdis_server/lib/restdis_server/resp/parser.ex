defmodule RestdisServer.RESP.Parser do
  @moduledoc """
  Incremental parser for RESP commands.

  Enforces Redis 7's request limits: before AUTH an array holds at most 10
  elements and a bulk at most 16384 bytes; after AUTH at most 1048576 elements
  and 512MB. A header or inline line may not exceed 64KB.
  """

  @max_line_bytes 64 * 1024
  @max_unauthenticated_array_count 10
  @max_unauthenticated_bulk_bytes 16_384
  @max_array_count 1_048_576
  @max_bulk_bytes 512 * 1024 * 1024

  @type command :: [binary() | nil]

  @type error_reason ::
          :invalid_multibulk_length
          | :invalid_bulk_length
          | :unauthenticated_multibulk_length
          | :unauthenticated_bulk_length
          | :too_big_inline_request
          | :too_big_count_string
          | :expected_bulk_string
          | :expected_crlf
          | {:bad_integer, binary()}

  @type parse_result ::
          {:ok, command(), rest :: binary()}
          | {:more, missing_bytes :: pos_integer()}
          | {:error, error_reason()}

  @doc """
  Parses one command off `data` under the limits for an authenticated or unauthenticated connection.

  `*-1` and `*0` parse to an empty command. When `data` is incomplete, returns
  `{:more, missing}` with the minimum number of extra bytes needed before a
  retry on the grown buffer can make progress.
  """
  @spec parse(binary(), boolean()) :: parse_result()
  def parse(data, authenticated? \\ false)

  def parse(<<"*", rest::binary>>, authenticated?) do
    with {:ok, count, rest} <- parse_integer_line(rest),
         :ok <- check_array_count(count, authenticated?) do
      parse_bulk_array(count, rest, [], authenticated?)
    end
  end

  def parse(data, _authenticated?) do
    case :binary.split(data, "\r\n") do
      [_] when byte_size(data) > @max_line_bytes -> {:error, :too_big_inline_request}
      [_] -> {:more, 1}
      [line, _rest] when byte_size(line) > @max_line_bytes -> {:error, :too_big_inline_request}
      [line, rest] -> {:ok, String.split(line, " ", trim: true), rest}
    end
  end

  @doc """
  Returns the Redis-style protocol error message for a parse error `reason`.
  """
  @spec format_error(error_reason()) :: String.t()
  def format_error(:invalid_multibulk_length), do: "invalid multibulk length"
  def format_error(:invalid_bulk_length), do: "invalid bulk length"
  def format_error(:unauthenticated_multibulk_length), do: "unauthenticated multibulk length"
  def format_error(:unauthenticated_bulk_length), do: "unauthenticated bulk length"
  def format_error(:too_big_inline_request), do: "too big inline request"
  def format_error(:too_big_count_string), do: "too big count string"
  def format_error(:expected_bulk_string), do: "expected '$'"
  def format_error(:expected_crlf), do: "expected CRLF after bulk string"
  def format_error({:bad_integer, _line}), do: "invalid length"

  defp check_array_count(count, _authenticated?) when count < -1,
    do: {:error, :invalid_multibulk_length}

  defp check_array_count(count, false) when count > @max_unauthenticated_array_count,
    do: {:error, :unauthenticated_multibulk_length}

  defp check_array_count(count, true) when count > @max_array_count,
    do: {:error, :invalid_multibulk_length}

  defp check_array_count(_count, _authenticated?), do: :ok

  defp check_bulk_length(len, _authenticated?) when len < -1,
    do: {:error, :invalid_bulk_length}

  defp check_bulk_length(len, false) when len > @max_unauthenticated_bulk_bytes,
    do: {:error, :unauthenticated_bulk_length}

  defp check_bulk_length(len, true) when len > @max_bulk_bytes,
    do: {:error, :invalid_bulk_length}

  defp check_bulk_length(_len, _authenticated?), do: :ok

  defp parse_bulk_array(n, rest, acc, _authenticated?) when n <= 0,
    do: {:ok, Enum.reverse(acc), rest}

  defp parse_bulk_array(n, data, acc, authenticated?) do
    with {:ok, item, rest} <- parse_one_bulk(data, authenticated?) do
      parse_bulk_array(n - 1, rest, [item | acc], authenticated?)
    end
  end

  defp parse_one_bulk(<<"$", rest::binary>>, authenticated?) do
    with {:ok, len, rest} <- parse_integer_line(rest),
         :ok <- check_bulk_length(len, authenticated?) do
      parse_bulk_bytes(len, rest)
    end
  end

  defp parse_one_bulk(<<>>, _authenticated?), do: {:more, 1}

  defp parse_one_bulk(_data, _authenticated?), do: {:error, :expected_bulk_string}

  defp parse_bulk_bytes(-1, rest), do: {:ok, nil, rest}

  defp parse_bulk_bytes(len, data) when byte_size(data) < len + 2,
    do: {:more, len + 2 - byte_size(data)}

  defp parse_bulk_bytes(len, data) do
    case data do
      <<bulk::binary-size(^len), "\r\n", rest::binary>> -> {:ok, bulk, rest}
      _ -> {:error, :expected_crlf}
    end
  end

  defp parse_integer_line(data) do
    case :binary.split(data, "\r\n") do
      [_] when byte_size(data) > @max_line_bytes ->
        {:error, :too_big_count_string}

      [_] ->
        {:more, 1}

      [line, _rest] when byte_size(line) > @max_line_bytes ->
        {:error, :too_big_count_string}

      [line, rest] ->
        case Integer.parse(line) do
          {n, ""} -> {:ok, n, rest}
          _ -> {:error, {:bad_integer, line}}
        end
    end
  end
end
