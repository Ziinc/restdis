defmodule RestdisServer.Commands.PgrstQuery do
  @moduledoc """
  Handles the RESP `PGRST.QUERY` command, serving cached PostgREST responses.
  """

  require OpenTelemetry.Tracer

  alias Restdis.Cache.Key
  alias Restdis.Cache.Router
  alias RestdisServer.Fallback
  alias RestdisServer.PGRST.QueryParser
  alias RestdisServer.PolicyStore
  alias RestdisServer.PostgREST.Fetcher
  alias RestdisServer.RESP.Encoder
  alias RestdisServer.Rewarm
  alias RestdisServer.TenantConfig

  @doc """
  Serves a PostgREST query, fetching from the origin and caching it on a miss.
  """
  @spec run(map(), [binary()]) :: {iodata(), map()}
  def run(state, [path | opts]) do
    OpenTelemetry.Tracer.with_span "resp.pgrst_query", %{
      attributes: %{"restdis.tenant_id" => state.tenant_id, "restdis.path" => path}
    } do
      ttl_ms = parse_ttl_opt(opts)
      rewarm_s = parse_rewarm_opt(opts)

      with {:ok, key, _params} <- QueryParser.parse(state.tenant_id, path),
           {:ok, config} <- TenantConfig.lookup_by_tenant_id(state.tenant_id) do
        wire_key = Key.encode(key)

        if rewarm_s do
          Rewarm.set_rewarm(state.tenant_id, wire_key, key, rewarm_s)
        end

        case Router.peek(state.tenant_id, key) do
          {:ok, _value} ->
            OpenTelemetry.Tracer.set_attribute("restdis.cache_result", "hit")
            Rewarm.touch(state.tenant_id, wire_key, key)
            {Encoder.bulk_string(wire_key), state}

          {:error, :unreachable} ->
            OpenTelemetry.Tracer.set_attribute("restdis.cache_result", "fallback")
            fallback_query(state, key, wire_key, config)

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
        case Router.put(state.tenant_id, key, body,
               ttl_ms: effective_ttl_ms,
               persist: policy.persist,
               persist_cap: config.persist_cap
             ) do
          :ok ->
            Rewarm.touch(state.tenant_id, wire_key, key)
            {Encoder.bulk_string(wire_key), state}

          {:error, :unreachable} ->
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

  defp fallback_query(state, key, wire_key, config) do
    case Fallback.fetch(state.tenant_id, key) do
      {:ok, body} ->
        ttl_ms = (config.default_ttl_s || 60) * 1000
        Restdis.Cache.put(state.tenant_id, key, body, ttl_ms: ttl_ms)
        {Encoder.bulk_string(wire_key), state}

      {:error, reason} ->
        {Encoder.error("ERR origin unavailable: #{inspect(reason)}"), state}
    end
  end

  defp maybe_cold_read(tenant_id, wire_key) do
    policy = PolicyStore.get(tenant_id, wire_key)

    if not is_nil(policy.rewarm_s) do
      :telemetry.execute(
        [:restdis_server, :rewarm, :cold_read],
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

  defp parse_rewarm_opt(opts) do
    opts
    |> Enum.chunk_every(2)
    |> Enum.find_value(&rewarm_s/1)
  end

  defp rewarm_s([k, v]) when is_binary(k) do
    case {String.upcase(k), Integer.parse(v)} do
      {"REWARM", {s, ""}} -> s
      _ -> nil
    end
  end

  defp rewarm_s(_pair), do: nil
end
