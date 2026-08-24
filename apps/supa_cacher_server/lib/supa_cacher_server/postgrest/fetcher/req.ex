defmodule SupaCacherServer.PostgREST.Fetcher.Req do
  @moduledoc """
  Fetcher implementation issuing HTTP requests to PostgREST with Req.
  """

  @behaviour SupaCacherServer.PostgREST.Fetcher

  require OpenTelemetry.Tracer

  alias SupaCacherServer.PostgREST.Fetcher

  @impl SupaCacherServer.PostgREST.Fetcher
  def fetch(tenant_id, key, config) do
    base_url = config[:replica_url] || config.pgrst_base_url
    path = Fetcher.path_for(key)

    OpenTelemetry.Tracer.with_span "postgrest.fetch", %{
      kind: :client,
      attributes: %{
        "restdis.tenant_id" => tenant_id,
        "http.url" => base_url <> path,
        "http.method" => "GET"
      }
    } do
      extra = Application.get_env(:supa_cacher_server, :req_options, [])
      trace_headers = :otel_propagator_text_map.inject([])

      req =
        Req.new(
          [
            base_url: base_url,
            headers: [{"apikey", config.pgrst_api_key} | trace_headers],
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
