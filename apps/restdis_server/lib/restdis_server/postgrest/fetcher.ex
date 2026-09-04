defmodule RestdisServer.PostgREST.Fetcher do
  @moduledoc """
  Behaviour and helpers for fetching a cache key from PostgREST.
  """

  alias Restdis.Cache.Key

  @callback fetch(tenant_id :: String.t(), key :: Key.t(), config :: map()) ::
              {:ok, body :: term()} | {:error, {:status, integer()} | term()}

  @spec fetch(String.t(), Key.t(), map()) ::
          {:ok, term()} | {:error, {:status, integer()} | term()}
  @doc """
  Fetches `key` from PostgREST using the configured fetcher implementation.
  """
  def fetch(tenant_id, key, config) do
    Application.get_env(
      :restdis_server,
      :postgrest_fetcher,
      RestdisServer.PostgREST.Fetcher.Req
    ).fetch(
      tenant_id,
      key,
      config
    )
  end

  @doc """
  Returns the PostgREST path a cache key was built from, optionally with its
  raw query string appended.
  """
  @spec path_for(Key.t(), String.t()) :: String.t()
  def path_for(key, query_string \\ "")

  def path_for(%Key{scope: :table, ident: ident}, query_string),
    do: append_query("/#{URI.encode(ident)}", query_string)

  def path_for(%Key{scope: :rpc, ident: ident}, query_string),
    do: append_query("/rpc/#{URI.encode(ident)}", query_string)

  def path_for(%Key{scope: :view, ident: ident}, query_string),
    do: append_query("/#{URI.encode(ident)}", query_string)

  defp append_query(path, nil), do: path
  defp append_query(path, ""), do: path
  defp append_query(path, query_string), do: path <> "?" <> query_string
end
