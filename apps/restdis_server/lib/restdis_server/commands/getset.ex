defmodule RestdisServer.Commands.Getset do
  @moduledoc """
  Handles the RESP `GETSET` command.
  """

  alias Restdis.Cache.Router
  alias RestdisServer.Commands.Support
  alias RestdisServer.RESP.Encoder

  @doc """
  Stores `value` under `wire_key` and replies with the previous value (nil
  bulk string if it didn't exist). Like Redis, this discards any existing
  TTL.
  """
  @spec run(map(), [binary()]) :: {iodata(), map()}
  def run(state, [wire_key, value]) do
    case Support.decode_raw_key(wire_key) do
      {:ok, key} -> swap(state, key, value)
      {:error, reply} -> {reply, state}
    end
  end

  def run(state, _),
    do: {Encoder.error("ERR wrong number of arguments for 'getset' command"), state}

  defp swap(state, key, value) do
    case Router.get(state.tenant_id, key) do
      {:ok, old} -> put_new(state, key, value, old)
      :miss -> put_new(state, key, value, nil)
      {:error, :unreachable} -> {Encoder.error("ERR cache node unreachable"), state}
    end
  end

  defp put_new(state, key, value, old) do
    case Router.put(state.tenant_id, key, value, []) do
      :ok -> {Encoder.bulk_string(old), state}
      {:error, :persist_cap} -> {Encoder.error("ERR persist cap reached for tenant"), state}
      {:error, :unreachable} -> {Encoder.error("ERR cache node unreachable"), state}
    end
  end
end
