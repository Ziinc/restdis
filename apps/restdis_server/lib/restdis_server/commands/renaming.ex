defmodule RestdisServer.Commands.Renaming do
  @moduledoc """
  Shared logic backing `RENAME` and `RENAMENX`.
  """

  alias Restdis.Cache.Router
  alias RestdisServer.Commands.Support
  alias RestdisServer.PolicyStore
  alias RestdisServer.RESP.Encoder

  @doc """
  Decodes `src_wire_key`/`dst_wire_key` and moves the value, preserving its
  remaining TTL. `overwrite?` controls whether an existing `dst_wire_key` is
  replaced; `on_success` and `on_missing_dst` build the reply for each case
  (renamed successfully, or skipped because destination already exists).
  """
  @spec move(map(), String.t(), String.t(), boolean(), fun(), fun()) :: {iodata(), map()}
  def move(state, src_wire_key, dst_wire_key, overwrite?, on_success, on_dst_exists) do
    with {:ok, src} <- Support.decode_raw_key(src_wire_key),
         {:ok, dst} <- Support.decode_raw_key(dst_wire_key) do
      fetch_src(state, src, src_wire_key, dst, overwrite?, on_success, on_dst_exists)
    else
      {:error, reply} -> {reply, state}
    end
  end

  defp fetch_src(state, src, src_wire_key, dst, overwrite?, on_success, on_dst_exists) do
    case Router.get(state.tenant_id, src) do
      {:ok, value} ->
        check_dst(state, src, src_wire_key, dst, value, overwrite?, on_success, on_dst_exists)

      :miss ->
        {Encoder.error("ERR no such key"), state}

      {:error, :unreachable} ->
        {Encoder.error("ERR cache node unreachable"), state}
    end
  end

  defp check_dst(state, src, src_wire_key, dst, value, true, on_success, _on_dst_exists) do
    copy_and_delete(state, src, src_wire_key, dst, value, on_success)
  end

  defp check_dst(state, src, src_wire_key, dst, value, false, on_success, on_dst_exists) do
    case Router.get(state.tenant_id, dst) do
      {:ok, _existing} -> on_dst_exists.(state)
      :miss -> copy_and_delete(state, src, src_wire_key, dst, value, on_success)
      {:error, :unreachable} -> {Encoder.error("ERR cache node unreachable"), state}
    end
  end

  defp copy_and_delete(state, src, src_wire_key, dst, value, on_success) do
    ttl_ms = Support.remaining_ttl_ms(state.tenant_id, src)
    opts = if is_integer(ttl_ms), do: [ttl_ms: ttl_ms], else: []

    case Router.put(state.tenant_id, dst, value, opts) do
      :ok ->
        Restdis.Cache.delete(state.tenant_id, src)
        PolicyStore.delete(state.tenant_id, src_wire_key)
        on_success.(state)

      {:error, :persist_cap} ->
        {Encoder.error("ERR persist cap reached for tenant"), state}

      {:error, :unreachable} ->
        {Encoder.error("ERR cache node unreachable"), state}
    end
  end
end
