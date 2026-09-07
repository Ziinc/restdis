defmodule RestdisServer.Commands.Persist do
  @moduledoc """
  Handles the RESP `PERSIST` command.

  Redis `PERSIST` removes a key's TTL entirely. Every entry here is subject
  to the disk cache's own eviction and cap accounting, so restdis caps this
  at the owning tenant's configured `max_ttl_s` instead of making the key
  immortal: `PERSIST` extends the key's TTL to that ceiling rather than
  clearing it, and always writes through to disk.
  """

  alias Restdis.Cache.Router
  alias RestdisServer.Commands.Support
  alias RestdisServer.RESP.Encoder
  alias RestdisServer.TenantConfig

  @default_max_ttl_s 2_592_000

  @doc """
  Extends `wire_key`'s TTL to the tenant's max TTL. Replies `1` if applied,
  `0` if the key doesn't exist.
  """
  @spec run(map(), [binary()]) :: {iodata(), map()}
  def run(state, [wire_key]) do
    case Support.decode_raw_key(wire_key) do
      {:ok, key} -> persist(state, key)
      {:error, reply} -> {reply, state}
    end
  end

  def run(state, _),
    do: {Encoder.error("ERR wrong number of arguments for 'persist' command"), state}

  defp persist(state, key) do
    case Router.get(state.tenant_id, key) do
      {:ok, value} -> apply_max_ttl(state, key, value)
      :miss -> {Encoder.integer(0), state}
      {:error, :unreachable} -> {Encoder.error("ERR cache node unreachable"), state}
    end
  end

  defp apply_max_ttl(state, key, value) do
    case Router.put(state.tenant_id, key, value, ttl_ms: max_ttl_ms(state.tenant_id)) do
      :ok -> {Encoder.integer(1), state}
      {:error, :persist_cap} -> {Encoder.error("ERR persist cap reached for tenant"), state}
      {:error, :unreachable} -> {Encoder.error("ERR cache node unreachable"), state}
    end
  end

  defp max_ttl_ms(tenant_id) do
    case TenantConfig.lookup_by_tenant_id(tenant_id) do
      {:ok, %{max_ttl_s: s}} when is_integer(s) and s > 0 -> s * 1000
      _ -> @default_max_ttl_s * 1000
    end
  end
end
