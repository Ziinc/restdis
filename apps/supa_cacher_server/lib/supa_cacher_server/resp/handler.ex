defmodule SupaCacherServer.RESP.Handler do
  @moduledoc """
  ThousandIsland handler running the RESP protocol over a TCP connection.
  """

  use ThousandIsland.Handler

  alias SupaCacherServer.Commands.Dispatcher
  alias SupaCacherServer.RESP.Encoder
  alias SupaCacherServer.RESP.Parser

  @impl ThousandIsland.Handler
  def handle_connection(_socket, _opts) do
    state = %{authenticated?: false, tenant_id: nil, buffer: <<>>}
    {:continue, state}
  end

  @impl ThousandIsland.Handler
  def handle_data(data, socket, state) do
    process_buffer(state.buffer <> data, socket, state)
  end

  defp process_buffer(buffer, socket, state) do
    case Parser.parse(buffer) do
      {:ok, command, rest} ->
        {reply, new_state} = Dispatcher.dispatch(state, command)
        ThousandIsland.Socket.send(socket, IO.iodata_to_binary(reply))
        process_buffer(rest, socket, %{new_state | buffer: <<>>})

      {:more, _rest} ->
        {:continue, %{state | buffer: buffer}}

      {:error, reason} ->
        msg = Encoder.error("ERR protocol error: #{inspect(reason)}")
        ThousandIsland.Socket.send(socket, IO.iodata_to_binary(msg))
        {:close, state}
    end
  end
end
