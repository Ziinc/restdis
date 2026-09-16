defmodule RestdisServer.Commands.Pexpire do
  @moduledoc """
  Handles the RESP `PEXPIRE` command.
  """

  alias RestdisServer.Commands.Expiry
  alias RestdisServer.RESP.Encoder

  @doc """
  Sets a TTL, in milliseconds, on `wire_key`.
  """
  @spec run(map(), [binary()]) :: {iodata(), map()}
  def run(state, [wire_key, millis]) do
    case Integer.parse(millis) do
      {n, ""} -> Expiry.set_ttl_ms(state, wire_key, n)
      _ -> {Encoder.error("ERR value is not an integer or out of range"), state}
    end
  end

  def run(state, _),
    do: {Encoder.error("ERR wrong number of arguments for 'pexpire' command"), state}
end
