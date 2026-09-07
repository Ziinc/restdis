defmodule RestdisServer.Commands.Set do
  @moduledoc """
  Handles the RESP `SET` command.

  `SET` writes a plain, user-managed key/value pair readable back via `GET`,
  `MGET`, `TTL`, `EXISTS` and removable via `DEL`. It supports
  `SET key value [EX seconds | PX milliseconds | KEEPTTL] [NX | XX]`.

  Two key namespaces are reserved and rejected by `SET`, since they are
  populated automatically elsewhere:

    * `pgrst:*` wire keys are the canonical cache keys returned by
      `PGRST.QUERY` and updated via `PGRST.POLICY`. They represent cached
      PostgREST query responses, not manually authored values.
    * Any other key containing a colon is reserved for the
      `<table>:<primary_key>` replicated dataset address space (see
      `RestdisReplicator.Dataset` and `GET`), which is populated by WAL-driven
      table replication.
  """

  alias Restdis.Cache.Key
  alias Restdis.Cache.Router
  alias RestdisServer.Commands.Support
  alias RestdisServer.RESP.Encoder
  alias RestdisServer.TenantConfig

  @doc """
  Stores `value` under `wire_key`, honouring `EX`/`PX`/`KEEPTTL` and
  `NX`/`XX` options.
  """
  @spec run(map(), [binary()]) :: {iodata(), map()}
  def run(state, [wire_key, value | rest]) do
    case Key.decode(wire_key) do
      {:ok, %Key{scope: :raw} = key} ->
        case parse_opts(rest) do
          {:ok, opts} -> put(state, key, value, opts)
          :error -> {Encoder.error("ERR syntax error"), state}
        end

      {:ok, %Key{}} ->
        {Encoder.error(
           "ERR pgrst:* keys are managed by PGRST.QUERY/PGRST.POLICY and cannot be set directly"
         ), state}

      :error ->
        {Encoder.error(
           "ERR SET only supports plain keys; pgrst:* and <table>:<primary_key> keys are reserved"
         ), state}
    end
  end

  def run(state, _), do: {Encoder.error("ERR wrong number of arguments for 'set' command"), state}

  defp put(state, _key, _value, %{nx: true, xx: true}) do
    {Encoder.error("ERR syntax error"), state}
  end

  defp put(state, key, value, opts) do
    case check_condition(state, key, opts) do
      :ok -> write(state, key, value, resolve_ttl_ms(state, key, opts))
      :skip -> {Encoder.bulk_string(nil), state}
      :unreachable -> {Encoder.error("ERR cache node unreachable"), state}
    end
  end

  defp check_condition(state, key, %{nx: true}) do
    case Router.get(state.tenant_id, key) do
      :miss -> :ok
      {:ok, _} -> :skip
      {:error, :unreachable} -> :unreachable
    end
  end

  defp check_condition(state, key, %{xx: true}) do
    case Router.get(state.tenant_id, key) do
      {:ok, _} -> :ok
      :miss -> :skip
      {:error, :unreachable} -> :unreachable
    end
  end

  defp check_condition(_state, _key, _opts), do: :ok

  defp resolve_ttl_ms(_state, _key, %{ttl_ms: ttl_ms}), do: ttl_ms

  defp resolve_ttl_ms(state, key, %{keepttl: true}) do
    case Support.remaining_ttl_ms(state.tenant_id, key) do
      ms when is_integer(ms) -> ms
      _ -> nil
    end
  end

  defp resolve_ttl_ms(_state, _key, _opts), do: nil

  defp write(state, key, value, ttl_ms) do
    put_opts = if ttl_ms, do: [ttl_ms: ttl_ms], else: []
    put_opts = put_opts ++ persist_cap_opt(state.tenant_id)

    case Router.put(state.tenant_id, key, value, put_opts) do
      :ok ->
        {Encoder.simple_string("OK"), state}

      {:error, :persist_cap} ->
        {Encoder.error("ERR persist cap reached for tenant"), state}

      {:error, :unreachable} ->
        {Encoder.error("ERR cache node unreachable"), state}
    end
  end

  # Threads the tenant's configured persist_cap to Restdis.Cache (its default, 50,000, only applies when none is passed).
  defp persist_cap_opt(tenant_id) do
    case TenantConfig.lookup_by_tenant_id(tenant_id) do
      {:ok, %{persist_cap: persist_cap}} when is_integer(persist_cap) ->
        [persist_cap: persist_cap]

      _ ->
        []
    end
  end

  defp parse_opts(rest), do: parse_opts(rest, %{})

  defp parse_opts([], acc), do: {:ok, acc}

  defp parse_opts(["EX", seconds | rest], acc) do
    case Integer.parse(seconds) do
      {n, ""} when n > 0 -> parse_opts(rest, Map.put(acc, :ttl_ms, n * 1000))
      _ -> :error
    end
  end

  defp parse_opts(["PX", millis | rest], acc) do
    case Integer.parse(millis) do
      {n, ""} when n > 0 -> parse_opts(rest, Map.put(acc, :ttl_ms, n))
      _ -> :error
    end
  end

  defp parse_opts(["KEEPTTL" | rest], acc), do: parse_opts(rest, Map.put(acc, :keepttl, true))
  defp parse_opts(["NX" | rest], acc), do: parse_opts(rest, Map.put(acc, :nx, true))
  defp parse_opts(["XX" | rest], acc), do: parse_opts(rest, Map.put(acc, :xx, true))
  defp parse_opts(_rest, _acc), do: :error
end
