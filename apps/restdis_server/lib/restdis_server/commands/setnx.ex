defmodule RestdisServer.Commands.Setnx do
  @moduledoc """
  Handles the RESP `SETNX` command.
  """

  alias Restdis.Cache.Router
  alias RestdisServer.Commands.Support
  alias RestdisServer.RESP.Encoder

  @doc """
  Stores `value` under `wire_key` only if it doesn't already exist. Replies
  `1` if set, `0` otherwise.
  """
  @spec run(map(), [binary()]) :: {iodata(), map()}
  def run(state, [wire_key, value]) do
    case Support.decode_raw_key(wire_key) do
      {:ok, key} -> put_if_absent(state, key, value)
      {:error, reply} -> {reply, state}
    end
  end

  def run(state, _),
    do: {Encoder.error("ERR wrong number of arguments for 'setnx' command"), state}

  defp put_if_absent(state, key, value) do
    case Router.get(state.tenant_id, key) do
      {:ok, _existing} -> {Encoder.integer(0), state}
      :miss -> do_put(state, key, value)
      {:error, :unreachable} -> {Encoder.error("ERR cache node unreachable"), state}
    end
  end

  defp do_put(state, key, value) do
    case Router.put(state.tenant_id, key, value, []) do
      :ok -> {Encoder.integer(1), state}
      {:error, :persist_cap} -> {Encoder.error("ERR persist cap reached for tenant"), state}
      {:error, :unreachable} -> {Encoder.error("ERR cache node unreachable"), state}
    end
  end
end
