defmodule SupaCacherServer.PostgREST.Fetcher.Req do
  @behaviour SupaCacherServer.PostgREST.Fetcher

  alias SupaCacherServer.PostgREST.Fetcher

  @impl true
  def fetch(_tenant_id, key, config) do
    base_url = config[:replica_url] || config.pgrst_base_url
    path = Fetcher.path_for(key)

    extra = Application.get_env(:supa_cacher_server, :req_options, [])

    req =
      Req.new(
        [base_url: base_url, headers: [{"apikey", config.pgrst_api_key}], retry: false] ++ extra
      )

    case Req.get(req, url: path) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:status, status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
