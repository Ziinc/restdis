defmodule RestdisServer.Commands.Append do
  @moduledoc """
  Handles the RESP `APPEND` command.
  """

  alias Restdis.Cache.Router
  alias RestdisServer.Commands.Support
  alias RestdisServer.RESP.Encoder

  @doc """
  Appends `value` to the string stored at `wire_key` (treating a missing key
  as empty) and replies with the resulting length. Preserves any existing
  TTL.
  """
  @spec run(map(), [binary()]) :: {iodata(), map()}
  def run(state, [wire_key, value]) do
    case Support.decode_raw_key(wire_key) do
      {:ok, key} -> do_append(state, key, value)
      {:error, reply} -> {reply, state}
    end
  end

  def run(state, _),
    do: {Encoder.error("ERR wrong number of arguments for 'append' command"), state}

  defp do_append(state, key, value) do
    case Router.get(state.tenant_id, key) do
      {:ok, existing} -> write(state, key, existing <> value)
      :miss -> write(state, key, value)
      {:error, :unreachable} -> {Encoder.error("ERR cache node unreachable"), state}
    end
  end

  defp write(state, key, new_value) do
    ttl_ms = Support.remaining_ttl_ms(state.tenant_id, key)
    opts = if is_integer(ttl_ms), do: [ttl_ms: ttl_ms], else: []

    case Router.put(state.tenant_id, key, new_value, opts) do
      :ok -> {Encoder.integer(byte_size(new_value)), state}
      {:error, :persist_cap} -> {Encoder.error("ERR persist cap reached for tenant"), state}
      {:error, :unreachable} -> {Encoder.error("ERR cache node unreachable"), state}
    end
  end
end
