defmodule RestdisServer.Commands.Set do
  @moduledoc """
  Handles the RESP `SET` command.
  """

  alias RestdisServer.RESP.Encoder

  @doc """
  Rejects the command; only `PGRST.*` keys are writable.
  """
  @spec run(map(), [binary()]) :: {iodata(), map()}
  def run(state, _args) do
    _ = state
    {Encoder.error("ERR only PGRST.* keys are supported"), state}
  end
end
