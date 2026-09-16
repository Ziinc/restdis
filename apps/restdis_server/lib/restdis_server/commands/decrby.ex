defmodule RestdisServer.Commands.Decrby do
  @moduledoc """
  Handles the RESP `DECRBY` command.
  """

  alias RestdisServer.Commands.Counter
  alias RestdisServer.RESP.Encoder

  @doc """
  Subtracts `amount` from the integer stored at `wire_key` and replies with
  the new value.
  """
  @spec run(map(), [binary()]) :: {iodata(), map()}
  def run(state, [wire_key, amount]) do
    case Integer.parse(amount) do
      {n, ""} -> Counter.apply_delta(state, wire_key, -n)
      _ -> {Encoder.error("ERR value is not an integer or out of range"), state}
    end
  end

  def run(state, _),
    do: {Encoder.error("ERR wrong number of arguments for 'decrby' command"), state}
end
