defmodule SupaCacherServer.PostgREST.Fetcher do
  alias SupaCacherCache.Key

  @callback fetch(tenant_id :: String.t(), key :: Key.t(), config :: map()) ::
              {:ok, body :: term()} | {:error, {:status, integer()} | term()}

  @spec fetch(String.t(), Key.t(), map()) :: {:ok, term()} | {:error, {:status, integer()} | term()}
  def fetch(tenant_id, key, config) do
    Application.get_env(:supa_cacher_server, :postgrest_fetcher, SupaCacherServer.PostgREST.Fetcher.Req).fetch(
      tenant_id,
      key,
      config
    )
  end

  @spec path_for(Key.t()) :: String.t()
  def path_for(%Key{scope: :table, ident: ident}), do: "/#{URI.encode(ident)}"
  def path_for(%Key{scope: :rpc, ident: ident}), do: "/rpc/#{URI.encode(ident)}"
  def path_for(%Key{scope: :view, ident: ident}), do: "/#{URI.encode(ident)}"
end
