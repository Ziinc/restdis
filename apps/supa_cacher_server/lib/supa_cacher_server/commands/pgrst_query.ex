defmodule SupaCacherServer.Commands.PgrstQuery do
  @moduledoc """
  Handles the RESP `PGRST.QUERY` command, serving cached PostgREST responses.
  """

  require OpenTelemetry.Tracer

  alias SupaCacherCache.Key
  alias SupaCacherServer.PGRST.QueryParser
  alias SupaCacherServer.PolicyStore
  alias SupaCacherServer.PostgREST.Fetcher
  alias SupaCacherServer.RESP.Encoder
  alias SupaCacherServer.Rewarm
  alias SupaCacherServer.TenantConfig

  @doc """
  Serves a PostgREST query, fetching from the origin and caching it on a miss.
  """
  @spec run(map(), [binary()]) :: {iodata(), map()}
  def run(state, [path | opts]) do
    OpenTelemetry.Tracer.with_span "resp.pgrst_query", %{
      attributes: %{"restdis.tenant_id" => state.tenant_id, "restdis.path" => path}
    } do
      ttl_ms = parse_ttl_opt(opts)

      with {:ok, key, _params} <- QueryParser.parse(path),
           {:ok, config} <- TenantConfig.lookup_by_tenant_id(state.tenant_id) do
        wire_key = Key.encode(key)

        case SupaCacherCache.peek(state.tenant_id, key) do
          {:ok, _value} ->
            OpenTelemetry.Tracer.set_attribute("restdis.cache_result", "hit")
            Rewarm.touch(state.tenant_id, wire_key, key)
            {Encoder.bulk_string(wire_key), state}

          :miss ->
            OpenTelemetry.Tracer.set_attribute("restdis.cache_result", "miss")
            maybe_cold_read(state.tenant_id, wire_key)
            fetch_and_cache(state, %{key: key, wire_key: wire_key, config: config}, ttl_ms)
        end
      else
        {:error, reason} ->
          {Encoder.error("ERR #{inspect(reason)}"), state}
      end
    end
  end

  def run(state, _),
    do: {Encoder.error("ERR wrong number of arguments for 'PGRST.QUERY' command"), state}

  defp fetch_and_cache(state, %{key: key, wire_key: wire_key, config: config}, ttl_ms) do
    default_ttl_ms = (config.default_ttl_s || 60) * 1000
    effective_ttl_ms = ttl_ms || default_ttl_ms
    policy = PolicyStore.get(state.tenant_id, wire_key)

    case Fetcher.fetch(state.tenant_id, key, config) do
      {:ok, body} ->
        case SupaCacherCache.put(state.tenant_id, key, body,
               ttl_ms: effective_ttl_ms,
               persist: policy.persist
             ) do
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

  defp maybe_cold_read(tenant_id, wire_key) do
    policy = PolicyStore.get(tenant_id, wire_key)

    if not is_nil(policy.rewarm_s) do
      :telemetry.execute(
        [:supa_cacher_server, :rewarm, :cold_read],
        %{count: 1},
        %{tenant_id: tenant_id}
      )
    end
  end

  defp parse_ttl_opt(opts) do
    opts
    |> Enum.chunk_every(2)
    |> Enum.find_value(&ttl_ms/1)
  end

  defp ttl_ms([k, v]) when is_binary(k) do
    case {String.upcase(k), Integer.parse(v)} do
      {"TTL", {s, ""}} -> s * 1000
      _ -> nil
    end
  end

  defp ttl_ms(_pair), do: nil
end
