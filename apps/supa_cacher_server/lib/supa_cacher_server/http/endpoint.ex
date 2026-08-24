defmodule SupaCacherServer.HTTP.Endpoint do
  use Plug.Router

  alias SupaCacherCache.Key
  alias SupaCacherServer.HTTP.Plug.Auth
  alias SupaCacherServer.HTTP.Plug.CacheHeaders
  alias SupaCacherServer.PGRST.QueryParser
  alias SupaCacherServer.PolicyStore
  alias SupaCacherServer.PostgREST.Fetcher
  alias SupaCacherServer.Rewarm

  plug(Plug.Logger)
  plug(:match)
  plug(:dispatch)

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  get "/pgrst/query" do
    conn = Auth.call(conn, [])
    if conn.halted, do: conn, else: handle_pgrst_query(conn, conn.params["path"])
  end

  post "/pgrst/policy" do
    conn = Auth.call(conn, [])

    if conn.halted do
      conn
    else
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case Jason.decode(body) do
        {:ok, params} -> handle_pgrst_policy(conn, params)
        {:error, _} -> send_resp(conn, 400, Jason.encode!(%{error: "invalid JSON"}))
      end
    end
  end

  match _ do
    send_resp(conn, 404, Jason.encode!(%{error: "not found"}))
  end

  defp handle_pgrst_query(conn, nil) do
    send_resp(conn, 400, Jason.encode!(%{error: "missing 'path' query parameter"}))
  end

  defp handle_pgrst_query(conn, path) do
    tenant_id = conn.assigns.tenant_id
    config = conn.assigns.tenant_config

    case QueryParser.parse(path) do
      {:ok, key, _params} ->
        wire_key = Key.encode(key)

        case SupaCacherCache.peek(tenant_id, key) do
          {:ok, value} ->
            Rewarm.touch(tenant_id, wire_key, key)

            conn
            |> CacheHeaders.put_cache_hit(ttl_remaining(tenant_id, key))
            |> put_resp_content_type("application/json")
            |> send_resp(200, Jason.encode!(value))

          :miss ->
            maybe_cold_read(tenant_id, wire_key)
            fetch_and_respond(conn, tenant_id, key, wire_key, config)
        end

      {:error, reason} ->
        send_resp(conn, 400, Jason.encode!(%{error: inspect(reason)}))
    end
  end

  defp fetch_and_respond(conn, tenant_id, key, wire_key, config) do
    ttl_ms = (config.default_ttl_s || 60) * 1000
    policy = PolicyStore.get(tenant_id, wire_key)

    case Fetcher.fetch(tenant_id, key, config) do
      {:ok, body} ->
        SupaCacherCache.put(tenant_id, key, body, ttl_ms: ttl_ms, persist: policy.persist)
        Rewarm.touch(tenant_id, wire_key, key)

        conn
        |> CacheHeaders.put_cache_miss(div(ttl_ms, 1000))
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(body))

      {:error, {:status, status}} ->
        send_resp(conn, status, Jason.encode!(%{error: "upstream error"}))

      {:error, reason} ->
        send_resp(conn, 502, Jason.encode!(%{error: inspect(reason)}))
    end
  end

  defp handle_pgrst_policy(conn, params) do
    wire_key = params["key"]
    tenant_id = conn.assigns.tenant_id

    case wire_key && Key.decode(wire_key) do
      {:ok, key} ->
        ttl_s = params["ttl_s"]
        rewarm = params["rewarm"]
        persist = params["persist"]

        existing = PolicyStore.get(tenant_id, wire_key)

        new_policy = %{
          rewarm_s: if(is_integer(rewarm), do: rewarm, else: existing.rewarm_s),
          persist: if(is_boolean(persist), do: persist, else: existing.persist)
        }

        PolicyStore.put(tenant_id, wire_key, new_policy)
        Rewarm.policy_changed(tenant_id, wire_key, key, new_policy)

        conn =
          if is_integer(ttl_s) and ttl_s > 0 do
            case SupaCacherCache.peek(tenant_id, key) do
              {:ok, value} ->
                SupaCacherCache.put(tenant_id, key, value, ttl_ms: ttl_s * 1000)

              :miss ->
                :ok
            end

            CacheHeaders.put_policy_ok(conn, ttl_s)
          else
            conn
          end

        send_resp(conn, 200, Jason.encode!(%{ok: true}))

      _ ->
        send_resp(conn, 400, Jason.encode!(%{error: "invalid or missing 'key'"}))
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

  defp ttl_remaining(tenant_id, key) do
    tid = :persistent_term.get({:sc_qc, tenant_id}, nil)

    if tid do
      case :ets.lookup(tid, key) do
        [{^key, _, :infinity}] -> -1
        [{^key, _, exp}] -> max(0, div(exp - System.monotonic_time(:millisecond), 1000))
        [] -> -2
      end
    else
      -2
    end
  end
end
