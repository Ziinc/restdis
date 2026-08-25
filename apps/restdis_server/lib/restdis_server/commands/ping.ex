defmodule RestdisServer.Commands.Ping do
  @moduledoc """
  Handles the RESP `PING` command.
  """

  alias RestdisServer.RESP.Encoder

  @doc """
  Replies with PONG.
  """
  @spec run(map(), [binary()]) :: {iodata(), map()}
  def run(state, []), do: {Encoder.simple_string("PONG"), state}
  def run(state, [msg | _]), do: {Encoder.bulk_string(msg), state}
end
