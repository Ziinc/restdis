defmodule SupaCacherServer.HTTP.Plug.Auth do
  @moduledoc """
  Plug authenticating HTTP requests and assigning the tenant id.
  """

  import Plug.Conn

  alias SupaCacherServer.TenantConfig

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> api_key] <- get_req_header(conn, "authorization"),
         {:ok, config} <- TenantConfig.lookup_by_api_key(api_key) do
      assign(conn, :tenant_id, config.tenant_id)
      |> assign(:tenant_config, config)
    else
      _ ->
        conn
        |> send_resp(401, Jason.encode!(%{error: "invalid or missing API key"}))
        |> halt()
    end
  end
end
