defmodule RestdisServer.Commands.Support do
  @moduledoc """
  Shared helpers for command handlers that read, mutate, expire, rename or
  copy a single plain (`:raw` scope) key.
  """

  alias Restdis.Cache.Key
  alias RestdisServer.RESP.Encoder

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
    case :persistent_term.get({:sc_qc, tenant_id}, nil) do
      nil ->
        :miss

      tid ->
        case :ets.lookup(tid, key) do
          [{^key, _value, :infinity, _last_access}] ->
            :infinity

          [{^key, _value, expires_at, _last_access}] ->
            now = System.monotonic_time(:millisecond)
            max(0, expires_at - now)

          [] ->
            :miss
        end
    end
  end
end
