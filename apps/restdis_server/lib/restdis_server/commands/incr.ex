defmodule RestdisServer.Commands.Incr do
  @moduledoc """
  Handles the RESP `INCR` command.
  """

  alias RestdisServer.Commands.Counter
  alias RestdisServer.RESP.Encoder

  @doc """
  Increments the integer stored at `wire_key` by one and replies with the new
  value.
  """
  @spec run(map(), [binary()]) :: {iodata(), map()}
  def run(state, [wire_key]), do: Counter.apply_delta(state, wire_key, 1)

  def run(state, _),
    do: {Encoder.error("ERR wrong number of arguments for 'incr' command"), state}
end
