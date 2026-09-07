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
  remaining TTL.

  `opts` takes:

    * `:overwrite?` - whether an existing `dst_wire_key` is replaced
    * `:on_success` - `state -> {iodata(), map()}` reply builder for a move
    * `:on_dst_exists` - same, built when the destination exists and
      `:overwrite?` is `false`
  """
  @spec move(map(), String.t(), String.t(), keyword()) :: {iodata(), map()}
  def move(state, src_wire_key, dst_wire_key, opts) do
    with {:ok, src} <- Support.decode_raw_key(src_wire_key),
         {:ok, dst} <- Support.decode_raw_key(dst_wire_key) do
      ctx = %{
        src_wire_key: src_wire_key,
        overwrite?: Keyword.fetch!(opts, :overwrite?),
        on_success: Keyword.fetch!(opts, :on_success),
        on_dst_exists: Keyword.get(opts, :on_dst_exists)
      }

      fetch_src(state, {src, dst}, ctx)
    else
      {:error, reply} -> {reply, state}
    end
  end

  defp fetch_src(state, {src, _dst} = keys, ctx) do
    case Router.get(state.tenant_id, src) do
      {:ok, value} -> check_dst(state, keys, value, ctx)
      :miss -> {Encoder.error("ERR no such key"), state}
      {:error, :unreachable} -> {Encoder.error("ERR cache node unreachable"), state}
    end
  end

  defp check_dst(state, keys, value, %{overwrite?: true} = ctx) do
    copy_and_delete(state, keys, value, ctx)
  end

  defp check_dst(state, {_src, dst} = keys, value, ctx) do
    case Router.get(state.tenant_id, dst) do
      {:ok, _existing} -> ctx.on_dst_exists.(state)
      :miss -> copy_and_delete(state, keys, value, ctx)
      {:error, :unreachable} -> {Encoder.error("ERR cache node unreachable"), state}
    end
  end

  defp copy_and_delete(state, {src, dst}, value, ctx) do
    ttl_ms = Support.remaining_ttl_ms(state.tenant_id, src)
    put_opts = if is_integer(ttl_ms), do: [ttl_ms: ttl_ms], else: []

    case Router.put(state.tenant_id, dst, value, put_opts) do
      :ok ->
        Restdis.Cache.delete(state.tenant_id, src)
        PolicyStore.delete(state.tenant_id, ctx.src_wire_key)
        ctx.on_success.(state)

      {:error, :persist_cap} ->
        {Encoder.error("ERR persist cap reached for tenant"), state}

      {:error, :unreachable} ->
        {Encoder.error("ERR cache node unreachable"), state}
    end
  end
end
