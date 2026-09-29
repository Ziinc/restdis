defmodule RestdisServer.RESP.Handler do
  @moduledoc """
  ThousandIsland handler running the RESP protocol over a TCP connection.

  Incoming bytes accumulate as iodata in `buffer`; the parser only reruns once
  `buffer_size` reaches `needed`, the size the pending command requires.
  """

  use ThousandIsland.Handler

  alias RestdisServer.Commands.Dispatcher
  alias RestdisServer.RESP.Encoder
  alias RestdisServer.RESP.Parser

  @impl ThousandIsland.Handler
  def handle_connection(_socket, _opts) do
    state = %{authenticated?: false, tenant_id: nil, buffer: <<>>, buffer_size: 0, needed: 0}
    {:continue, state}
  end

  @impl ThousandIsland.Handler
  def handle_data(data, socket, state) do
    buffer = [state.buffer | data]
    buffer_size = state.buffer_size + byte_size(data)

    if buffer_size < state.needed do
      {:continue, %{state | buffer: buffer, buffer_size: buffer_size}}
    else
      process_buffer(IO.iodata_to_binary(buffer), socket, state)
    end
  end

  defp process_buffer(buffer, socket, state) do
    case Parser.parse(buffer, state.authenticated?) do
      {:ok, [], rest} ->
        process_buffer(rest, socket, state)

      {:ok, command, rest} ->
        {reply, new_state} = Dispatcher.dispatch(state, command)
        ThousandIsland.Socket.send(socket, IO.iodata_to_binary(reply))
        continue_or_close(rest, socket, new_state)

      {:more, missing} ->
        size = byte_size(buffer)
        {:continue, %{state | buffer: buffer, buffer_size: size, needed: size + missing}}

      {:error, reason} ->
        msg = Encoder.error("ERR Protocol error: " <> Parser.format_error(reason))
        ThousandIsland.Socket.send(socket, IO.iodata_to_binary(msg))
        {:close, state}
    end
  end

  # QUIT sets `close?`; anything pipelined after it is dropped, as in Redis.
  defp continue_or_close(_rest, _socket, %{close?: true} = state), do: {:close, state}
  defp continue_or_close(rest, socket, state), do: process_buffer(rest, socket, state)
end
