defmodule RestdisServer.PostgREST.Fetcher.Req do
  @moduledoc """
  Fetcher implementation issuing HTTP requests to PostgREST with Req.

  The upstream credential is the one recorded for the key in
  `RestdisServer.QueryStore`, else the request's `:pgrst_credential`. With
  neither, the fetch returns `{:error, :unknown_query}` without an upstream
  request, so a key is never refetched with the tenant's `pgrst_api_key`.

  The credential is always sent as `apikey`, and also as
  `Authorization: Bearer` when it is JWT-shaped, since PostgREST rejects a
  non-JWT Authorization header.
  """

  @behaviour RestdisServer.PostgREST.Fetcher

  require OpenTelemetry.Tracer

  alias Restdis.Cache.Key
  alias RestdisServer.PostgREST.Fetcher
  alias RestdisServer.QueryStore

  @impl RestdisServer.PostgREST.Fetcher
  def fetch(tenant_id, key, config) do
    wire_key = Key.encode(key)

    case QueryStore.credential(tenant_id, wire_key) || config[:pgrst_credential] do
      nil -> {:error, :unknown_query}
      credential -> request(tenant_id, key, config, credential)
    end
  end

  @doc """
  Returns whether `credential` is JWT-shaped: three non-empty base64url
  segments separated by `.`.
  """
  @spec jwt?(String.t()) :: boolean()
  def jwt?(credential), do: String.match?(credential, ~r/\A[\w-]+\.[\w-]+\.[\w-]+\z/)

  defp auth_headers(credential) do
    if jwt?(credential),
      do: [{"apikey", credential}, {"authorization", "Bearer " <> credential}],
      else: [{"apikey", credential}]
  end

  defp request(tenant_id, key, config, credential) do
    base_url = config[:replica_url] || config.pgrst_base_url
    path = Fetcher.path_for(key, QueryStore.get(tenant_id, Key.encode(key)))

    OpenTelemetry.Tracer.with_span "postgrest.fetch", %{
      kind: :client,
      attributes: %{
        "restdis.tenant_id" => tenant_id,
        "http.url" => base_url <> path,
        "http.method" => "GET"
      }
    } do
      extra = Application.get_env(:restdis_server, :req_options, [])
      trace_headers = :otel_propagator_text_map.inject([])

      req =
        Req.new(
          [
            base_url: base_url,
            headers: auth_headers(credential) ++ trace_headers,
            retry: false
          ] ++ extra
        )

      case Req.get(req, url: path) do
        {:ok, %{status: 200, body: body}} ->
          {:ok, body}

        {:ok, %{status: status}} ->
          OpenTelemetry.Tracer.set_attribute("http.status_code", status)
          {:error, {:status, status}}

        {:error, reason} ->
          OpenTelemetry.Tracer.set_status(:error, inspect(reason))
          {:error, reason}
      end
    end
  end
end
