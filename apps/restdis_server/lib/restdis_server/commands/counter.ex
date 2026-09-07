defmodule RestdisServer.Commands.Counter do
  @moduledoc """
  Shared read-modify-write arithmetic backing `INCR`, `INCRBY`, `DECR` and
  `DECRBY`.

  The underlying key/value store has no atomic counter primitive, so this is
  a plain get-then-put: two concurrent deltas on the same key can race. This
  is an acceptable limitation given the current architecture, same as
  `SETNX`.
  """

  alias Restdis.Cache.Router
  alias RestdisServer.Commands.Support
  alias RestdisServer.RESP.Encoder

  @doc """
  Adds `delta` to the integer stored at `wire_key`, treating a missing key as
  zero, and replies with the new value.
  """
  @spec apply_delta(map(), String.t(), integer()) :: {iodata(), map()}
  def apply_delta(state, wire_key, delta) do
    case Support.decode_raw_key(wire_key) do
      {:ok, key} -> read(state, key, delta)
      {:error, reply} -> {reply, state}
    end
  end

  defp read(state, key, delta) do
    case Router.get(state.tenant_id, key) do
      {:ok, value} -> parse_and_put(state, key, value, delta)
      :miss -> parse_and_put(state, key, "0", delta)
      {:error, :unreachable} -> {Encoder.error("ERR cache node unreachable"), state}
    end
  end

  defp parse_and_put(state, key, value, delta) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> put(state, key, n + delta)
      _ -> {Encoder.error("ERR value is not an integer or out of range"), state}
    end
  end

  defp parse_and_put(state, _key, _value, _delta) do
    {Encoder.error("ERR value is not an integer or out of range"), state}
  end

  defp put(state, key, new_value) do
    ttl_ms = Support.remaining_ttl_ms(state.tenant_id, key)
    opts = if is_integer(ttl_ms), do: [ttl_ms: ttl_ms], else: []

    case Router.put(state.tenant_id, key, Integer.to_string(new_value), opts) do
      :ok -> {Encoder.integer(new_value), state}
      {:error, :persist_cap} -> {Encoder.error("ERR persist cap reached for tenant"), state}
      {:error, :unreachable} -> {Encoder.error("ERR cache node unreachable"), state}
    end
  end
end
