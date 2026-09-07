defmodule RestdisServer.Commands.Expire do
  @moduledoc """
  Handles the RESP `EXPIRE` command.
  """

  alias RestdisServer.Commands.Expiry
  alias RestdisServer.RESP.Encoder

  @doc """
  Sets a TTL, in seconds, on `wire_key`.
  """
  @spec run(map(), [binary()]) :: {iodata(), map()}
  def run(state, [wire_key, seconds]) do
    case Integer.parse(seconds) do
      {n, ""} -> Expiry.set_ttl_ms(state, wire_key, n * 1000)
      _ -> {Encoder.error("ERR value is not an integer or out of range"), state}
    end
  end

  def run(state, _),
    do: {Encoder.error("ERR wrong number of arguments for 'expire' command"), state}
end
