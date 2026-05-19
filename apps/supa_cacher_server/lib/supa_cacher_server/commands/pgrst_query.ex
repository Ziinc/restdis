defmodule SupaCacherServer.Commands.PgrstQuery do
  alias SupaCacherCache.Key
  alias SupaCacherServer.PGRST.QueryParser
  alias SupaCacherServer.RESP.Encoder
  alias SupaCacherServer.TenantConfig

  @spec run(map(), [binary()]) :: {iodata(), map()}
  def run(state, [path | opts]) do
    ttl_ms = parse_ttl_opt(opts)

    with {:ok, key, _params} <- QueryParser.parse(path),
         {:ok, config} <- TenantConfig.lookup_by_tenant_id(state.tenant_id) do
      case SupaCacherCache.peek(state.tenant_id, key) do
        {:ok, _value} ->
          {Encoder.bulk_string(Key.encode(key)), state}

        :miss ->
          fetch_and_cache(state, key, config, ttl_ms)
      end
    else
      {:error, reason} ->
        {Encoder.error("ERR #{inspect(reason)}"), state}
    end
  end

  def run(state, _), do: {Encoder.error("ERR wrong number of arguments for 'PGRST.QUERY' command"), state}

  defp fetch_and_cache(state, key, config, ttl_ms) do
    base_url = config[:replica_url] || config.pgrst_base_url
    path = key_to_path(key)
    default_ttl_ms = (config.default_ttl_s || 60) * 1000
    effective_ttl_ms = ttl_ms || default_ttl_ms

    extra = Application.get_env(:supa_cacher_server, :req_options, [])
    req = Req.new([base_url: base_url, headers: [{"apikey", config.pgrst_api_key}], retry: false] ++ extra)

    case Req.get(req, url: path) do
      {:ok, %{status: 200, body: body}} ->
        put_opts = [ttl_ms: effective_ttl_ms]
        SupaCacherCache.put(state.tenant_id, key, body, put_opts)
        {Encoder.bulk_string(Key.encode(key)), state}

      {:ok, %{status: status}} ->
        {Encoder.error("ERR PostgREST returned #{status}"), state}

      {:error, reason} ->
        {Encoder.error("ERR fetch failed: #{inspect(reason)}"), state}
    end
  end

  defp key_to_path(%Key{scope: :table, ident: ident}), do: "/#{URI.encode(ident)}"
  defp key_to_path(%Key{scope: :rpc, ident: ident}), do: "/rpc/#{URI.encode(ident)}"
  defp key_to_path(%Key{scope: :view, ident: ident}), do: "/#{URI.encode(ident)}"

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
