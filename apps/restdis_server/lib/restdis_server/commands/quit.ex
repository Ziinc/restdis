defmodule RestdisServer.Commands.Quit do
  @moduledoc """
  Handles the RESP `QUIT` command.
  """

  alias RestdisServer.RESP.Encoder

  @doc """
  Replies OK and marks the connection to be closed once the reply is sent.
  """
  @spec run(map(), [binary()]) :: {iodata(), map()}
  def run(state, _args), do: {Encoder.simple_string("OK"), Map.put(state, :close?, true)}
end
