defmodule SupaCacherServer.Commands.PgrstQuery do
  alias SupaCacherCache.Key
  alias SupaCacherServer.PGRST.QueryParser
  alias SupaCacherServer.PolicyStore
  alias SupaCacherServer.PostgREST.Fetcher
  alias SupaCacherServer.RESP.Encoder
  alias SupaCacherServer.Rewarm
  alias SupaCacherServer.TenantConfig

  @spec run(map(), [binary()]) :: {iodata(), map()}
  def run(state, [path | opts]) do
    ttl_ms = parse_ttl_opt(opts)

    with {:ok, key, _params} <- QueryParser.parse(path),
         {:ok, config} <- TenantConfig.lookup_by_tenant_id(state.tenant_id) do
      wire_key = Key.encode(key)

      case SupaCacherCache.peek(state.tenant_id, key) do
        {:ok, _value} ->
          Rewarm.touch(state.tenant_id, wire_key, key)
          {Encoder.bulk_string(wire_key), state}

        :miss ->
          fetch_and_cache(state, key, wire_key, config, ttl_ms)
      end
    else
      {:error, reason} ->
        {Encoder.error("ERR #{inspect(reason)}"), state}
    end
  end

  def run(state, _), do: {Encoder.error("ERR wrong number of arguments for 'PGRST.QUERY' command"), state}

  defp fetch_and_cache(state, key, wire_key, config, ttl_ms) do
    default_ttl_ms = (config.default_ttl_s || 60) * 1000
    effective_ttl_ms = ttl_ms || default_ttl_ms
    policy = PolicyStore.get(state.tenant_id, wire_key)

    case Fetcher.fetch(state.tenant_id, key, config) do
      {:ok, body} ->
        case SupaCacherCache.put(state.tenant_id, key, body, ttl_ms: effective_ttl_ms, persist: policy.persist) do
          :ok ->
            Rewarm.touch(state.tenant_id, wire_key, key)
            {Encoder.bulk_string(wire_key), state}

          {:error, :persist_cap} ->
            {Encoder.error("ERR persist cap reached"), state}
        end

      {:error, {:status, status}} ->
        {Encoder.error("ERR PostgREST returned #{status}"), state}

      {:error, reason} ->
        {Encoder.error("ERR fetch failed: #{inspect(reason)}"), state}
    end
  end

  defp parse_ttl_opt(opts) do
    opts
    |> Enum.chunk_every(2)
    |> Enum.find_value(fn
      [k, v] when is_binary(k) ->
        if String.upcase(k) == "TTL" do
          case Integer.parse(v) do
            {s, ""} -> s * 1000
            _ -> nil
          end
        end

      _ ->
        nil
    end)
  end
end
