defmodule RestdisServer.PGRST.QueryParser do
  @moduledoc """
  Parses a PostgREST request path into a cache key and its query params.
  """

  alias Restdis.Cache.Key
  alias RestdisServer.QueryStore

  @type parse_result :: {:ok, Key.t(), params_map :: map()} | {:error, reason :: term()}

  @doc """
  Parses a PostgREST path into a cache key and the decoded query params.

  Also records the raw query string of the resulting key in the
  `RestdisServer.QueryStore` (keyed by `tenant_id` and the key's wire
  representation) so that origin fetches issued later for this key -
  including cache-miss, rewarm, and fallback fetches - can forward the
  original query string to PostgREST.
  """
  @spec parse(String.t(), String.t()) :: parse_result()
  def parse(tenant_id, path) when is_binary(tenant_id) and is_binary(path) do
    uri = URI.parse(path)

    with {:ok, ident} <- extract_ident(uri.path) do
      scope = infer_scope(uri.path)
      params = decode_params(uri.query)
      key = Key.build(scope, ident, params)
      QueryStore.put(tenant_id, Key.encode(key), uri.query || "")
      {:ok, key, params}
    end
  end

  defp extract_ident(nil), do: {:error, :missing_path}

  defp extract_ident(path) do
    case String.split(path, "/", trim: true) do
      ["rpc", ident | _] -> {:ok, ident}
      [ident | _] -> {:ok, ident}
      [] -> {:error, :empty_path}
    end
  end

  defp infer_scope(path) do
    case String.split(path, "/", trim: true) do
      ["rpc" | _] -> :rpc
      _ -> :table
    end
  end

  defp decode_params(nil), do: %{}

  defp decode_params(query) do
    URI.decode_query(query)
  end
end
