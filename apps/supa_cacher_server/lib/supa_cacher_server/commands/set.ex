defmodule SupaCacherServer.Commands.Set do
  alias SupaCacherServer.RESP.Encoder

  @spec run(map(), [binary()]) :: {iodata(), map()}
  def run(state, _args) do
    _ = state
    {Encoder.error("ERR only PGRST.* keys are supported"), state}
  end
end
