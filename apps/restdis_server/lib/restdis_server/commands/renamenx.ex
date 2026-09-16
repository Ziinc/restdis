defmodule RestdisServer.Commands.Renamenx do
  @moduledoc """
  Handles the RESP `RENAMENX` command.
  """

  alias RestdisServer.Commands.Renaming
  alias RestdisServer.RESP.Encoder

  @doc """
  Moves the value at `src_wire_key` to `dst_wire_key`, only if
  `dst_wire_key` doesn't already exist. Replies `1` if renamed, `0`
  otherwise.
  """
  @spec run(map(), [binary()]) :: {iodata(), map()}
  def run(state, [src_wire_key, dst_wire_key]) do
    Renaming.move(state, src_wire_key, dst_wire_key,
      overwrite?: false,
      on_success: &{Encoder.integer(1), &1},
      on_dst_exists: &{Encoder.integer(0), &1}
    )
  end

  def run(state, _),
    do: {Encoder.error("ERR wrong number of arguments for 'renamenx' command"), state}
end
