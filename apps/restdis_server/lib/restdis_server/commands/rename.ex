defmodule RestdisServer.Commands.Rename do
  @moduledoc """
  Handles the RESP `RENAME` command.
  """

  alias RestdisServer.Commands.Renaming
  alias RestdisServer.RESP.Encoder

  @doc """
  Moves the value at `src_wire_key` to `dst_wire_key`, overwriting any
  existing value there.
  """
  @spec run(map(), [binary()]) :: {iodata(), map()}
  def run(state, [src_wire_key, dst_wire_key]) do
    Renaming.move(
      state,
      src_wire_key,
      dst_wire_key,
      true,
      &{Encoder.simple_string("OK"), &1},
      nil
    )
  end

  def run(state, _),
    do: {Encoder.error("ERR wrong number of arguments for 'rename' command"), state}
end
