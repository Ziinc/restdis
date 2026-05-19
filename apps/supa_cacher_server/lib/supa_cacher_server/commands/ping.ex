defmodule SupaCacherServer.Commands.Ping do
  alias SupaCacherServer.RESP.Encoder

  @spec run(map(), [binary()]) :: {iodata(), map()}
  def run(state, []), do: {Encoder.simple_string("PONG"), state}
  def run(state, [msg | _]), do: {Encoder.bulk_string(msg), state}
end
