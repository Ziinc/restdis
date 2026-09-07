defmodule RestdisServer.Commands.Expiry do
  @moduledoc """
  Shared logic backing `EXPIRE` and `PEXPIRE`.
  """

  alias Restdis.Cache.Router
  alias RestdisServer.Commands.Support
  alias RestdisServer.RESP.Encoder

  @doc """
  Sets a TTL of `ttl_ms` milliseconds on `wire_key`. Replies `1` if the TTL
  was set, `0` if the key doesn't exist. A non-positive `ttl_ms` deletes the
  key immediately, matching Redis.
  """
  @spec set_ttl_ms(map(), String.t(), integer()) :: {iodata(), map()}
  def set_ttl_ms(state, wire_key, ttl_ms) do
    case Support.decode_raw_key(wire_key) do
      {:ok, key} -> apply_ttl(state, key, wire_key, ttl_ms)
      {:error, reply} -> {reply, state}
    end
  end

  defp apply_ttl(state, key, wire_key, ttl_ms) when ttl_ms <= 0 do
    case Router.get(state.tenant_id, key) do
      {:ok, _value} ->
        Restdis.Cache.delete(state.tenant_id, key)
        RestdisServer.PolicyStore.delete(state.tenant_id, wire_key)
        {Encoder.integer(1), state}

      :miss ->
        {Encoder.integer(0), state}

      {:error, :unreachable} ->
        {Encoder.error("ERR cache node unreachable"), state}
    end
  end

  defp apply_ttl(state, key, _wire_key, ttl_ms) do
    case Router.get(state.tenant_id, key) do
      {:ok, value} -> put_with_ttl(state, key, value, ttl_ms)
      :miss -> {Encoder.integer(0), state}
      {:error, :unreachable} -> {Encoder.error("ERR cache node unreachable"), state}
    end
  end

  defp put_with_ttl(state, key, value, ttl_ms) do
    case Router.put(state.tenant_id, key, value, ttl_ms: ttl_ms) do
      :ok -> {Encoder.integer(1), state}
      {:error, :persist_cap} -> {Encoder.error("ERR persist cap reached for tenant"), state}
      {:error, :unreachable} -> {Encoder.error("ERR cache node unreachable"), state}
    end
  end
end
