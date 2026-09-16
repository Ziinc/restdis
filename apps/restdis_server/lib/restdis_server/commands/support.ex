defmodule RestdisServer.Commands.Support do
  @moduledoc """
  Shared helpers for command handlers that read, mutate, expire, rename or
  copy a single plain (`:raw` scope) key.
  """

  alias Restdis.Cache.Key
  alias RestdisServer.RESP.Encoder
  alias RestdisServer.TenantConfig

  @doc """
  Decodes `wire_key`, rejecting `pgrst:*` and `<table>:<primary_key>` keys.

  Mutating commands (`INCR`, `APPEND`, `RENAME`, ...) only operate on plain,
  user-managed keys written via `SET`, mirroring the restriction `SET` itself
  enforces.
  """
  @spec decode_raw_key(String.t()) :: {:ok, Key.t()} | {:error, iodata()}
  def decode_raw_key(wire_key) do
    case Key.decode(wire_key) do
      {:ok, %Key{scope: :raw} = key} ->
        {:ok, key}

      {:ok, %Key{}} ->
        {:error,
         Encoder.error(
           "ERR pgrst:* keys are managed by PGRST.QUERY/PGRST.POLICY and cannot be modified directly"
         )}

      :error ->
        {:error,
         Encoder.error(
           "ERR this command only supports plain keys; pgrst:* and <table>:<primary_key> keys are reserved"
         )}
    end
  end

  @doc """
  Returns the milliseconds remaining before `key` expires, `:infinity` for a
  key with no TTL, or `:miss` if it isn't held in this node's query cache.
  """
  @spec remaining_ttl_ms(String.t(), Key.t()) :: non_neg_integer() | :infinity | :miss
  def remaining_ttl_ms(tenant_id, key) do
    Restdis.Cache.ttl(tenant_id, key)
  end

  @doc """
  Returns `[persist_cap: cap]` for the tenant's configured `persist_cap`, or
  `[]` if the tenant isn't found. Threads through to `Restdis.Cache.put/4`
  and `Restdis.Cache.set_persist/4` so the cap they enforce always reflects
  the tenant's own `persist_cap` rather than the library's fallback default.
  """
  @spec persist_cap_opt(String.t()) :: keyword()
  def persist_cap_opt(tenant_id) do
    case TenantConfig.lookup_by_tenant_id(tenant_id) do
      {:ok, %{persist_cap: persist_cap}} when is_integer(persist_cap) ->
        [persist_cap: persist_cap]

      _ ->
        []
    end
  end
end
