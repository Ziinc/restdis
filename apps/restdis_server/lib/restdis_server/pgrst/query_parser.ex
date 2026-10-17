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

  Only `/<table_or_view>` and `/rpc/<function>` are accepted; any further
  path segments return `{:error, :unsupported_path}`, since PostgREST
  exposes no sub-resource paths.
  """
  @spec parse(String.t(), String.t()) :: parse_result()
  def parse(tenant_id, path) when is_binary(tenant_id) and is_binary(path) do
    uri = URI.parse(path)

    with {:ok, scope, ident} <- split_path(uri.path) do
      pairs = decode_pairs(uri.query)
      key = Key.build(scope, ident, [], pairs)
      QueryStore.put(tenant_id, Key.encode(key), uri.query || "")
      {:ok, key, Map.new(pairs)}
    end
  end

  defp split_path(nil), do: {:error, :missing_path}

  defp split_path(path) do
    case String.split(path, "/", trim: true) do
      ["rpc", ident] -> {:ok, :rpc, ident}
      ["rpc", _ident | _rest] -> {:error, :unsupported_path}
      [ident] -> {:ok, :table, ident}
      [_ident | _rest] -> {:error, :unsupported_path}
      [] -> {:error, :empty_path}
    end
  end

  defp decode_pairs(nil), do: []

  defp decode_pairs(query), do: query |> URI.query_decoder() |> Enum.to_list()
end
