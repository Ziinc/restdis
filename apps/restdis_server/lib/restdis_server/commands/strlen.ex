defmodule RestdisServer.Commands.Strlen do
  @moduledoc """
  Handles the RESP `STRLEN` command.
  """

  alias Restdis.Cache.Router
  alias RestdisServer.Commands.Support
  alias RestdisServer.RESP.Encoder

  @doc """
  Replies with the byte length of the string stored at `wire_key`, or `0` if
  it doesn't exist.
  """
  @spec run(map(), [binary()]) :: {iodata(), map()}
  def run(state, [wire_key]) do
    case Support.decode_raw_key(wire_key) do
      {:ok, key} -> length_of(state, key)
      {:error, reply} -> {reply, state}
    end
  end

  def run(state, _),
    do: {Encoder.error("ERR wrong number of arguments for 'strlen' command"), state}

  defp length_of(state, key) do
    case Router.get(state.tenant_id, key) do
      {:ok, value} -> {Encoder.integer(byte_size(value)), state}
      :miss -> {Encoder.integer(0), state}
      {:error, :unreachable} -> {Encoder.error("ERR cache node unreachable"), state}
    end
  end
end
