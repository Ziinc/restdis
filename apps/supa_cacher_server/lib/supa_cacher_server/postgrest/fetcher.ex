defmodule SupaCacherServer.PostgREST.Fetcher do
  @moduledoc """
  Behaviour and helpers for fetching a cache key from PostgREST.
  """

  alias SupaCacherCache.Key

  @callback fetch(tenant_id :: String.t(), key :: Key.t(), config :: map()) ::
              {:ok, body :: term()} | {:error, {:status, integer()} | term()}

  @spec fetch(String.t(), Key.t(), map()) ::
          {:ok, term()} | {:error, {:status, integer()} | term()}
  @doc """
  Fetches `key` from PostgREST using the configured fetcher implementation.
  """
  def fetch(tenant_id, key, config) do
    Application.get_env(
      :supa_cacher_server,
      :postgrest_fetcher,
      SupaCacherServer.PostgREST.Fetcher.Req
    ).fetch(
      tenant_id,
      key,
      config
    )
  end

  @doc """
  Returns the PostgREST path a cache key was built from.
  """
  @spec path_for(Key.t()) :: String.t()
  def path_for(%Key{scope: :table, ident: ident}), do: "/#{URI.encode(ident)}"
  def path_for(%Key{scope: :rpc, ident: ident}), do: "/rpc/#{URI.encode(ident)}"
  def path_for(%Key{scope: :view, ident: ident}), do: "/#{URI.encode(ident)}"
end
