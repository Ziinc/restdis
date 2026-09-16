defmodule RestdisServer.Commands.Copy do
  @moduledoc """
  Handles the RESP `COPY` command.
  """

  alias Restdis.Cache.Router
  alias RestdisServer.Commands.Support
  alias RestdisServer.RESP.Encoder

  @doc """
  Copies the value at `src_wire_key` to `dst_wire_key`, preserving its
  remaining TTL. Replies `1` if copied, `0` if the source is missing or the
  destination already exists (unless `REPLACE` is given).
  """
  @spec run(map(), [binary()]) :: {iodata(), map()}
  def run(state, [src_wire_key, dst_wire_key]),
    do: do_run(state, src_wire_key, dst_wire_key, false)

  def run(state, [src_wire_key, dst_wire_key, "REPLACE"]),
    do: do_run(state, src_wire_key, dst_wire_key, true)

  def run(state, _),
    do: {Encoder.error("ERR wrong number of arguments for 'copy' command"), state}

  defp do_run(state, src_wire_key, dst_wire_key, replace?) do
    with {:ok, src} <- Support.decode_raw_key(src_wire_key),
         {:ok, dst} <- Support.decode_raw_key(dst_wire_key) do
      copy(state, {src, dst}, replace?)
    else
      {:error, reply} -> {reply, state}
    end
  end

  defp copy(state, {src, _dst} = keys, replace?) do
    case Router.get(state.tenant_id, src) do
      {:ok, value} -> maybe_write(state, keys, value, replace?)
      :miss -> {Encoder.integer(0), state}
      {:error, :unreachable} -> {Encoder.error("ERR cache node unreachable"), state}
    end
  end

  defp maybe_write(state, {_src, dst} = keys, value, replace?) do
    case Router.get(state.tenant_id, dst) do
      {:ok, _existing} when not replace? -> {Encoder.integer(0), state}
      {:error, :unreachable} -> {Encoder.error("ERR cache node unreachable"), state}
      _ -> write(state, keys, value)
    end
  end

  defp write(state, {src, dst}, value) do
    ttl_ms = Support.remaining_ttl_ms(state.tenant_id, src)
    opts = if is_integer(ttl_ms), do: [ttl_ms: ttl_ms], else: []

    case Router.put(state.tenant_id, dst, value, opts) do
      :ok -> {Encoder.integer(1), state}
      {:error, :persist_cap} -> {Encoder.error("ERR persist cap reached for tenant"), state}
      {:error, :unreachable} -> {Encoder.error("ERR cache node unreachable"), state}
    end
  end
end
