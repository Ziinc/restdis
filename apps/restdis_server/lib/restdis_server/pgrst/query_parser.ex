defmodule RestdisServer.PGRST.QueryParser do
  @moduledoc """
  Parses a PostgREST request path into a cache key and its query params.
  """

  alias Restdis.Cache.Key
  alias RestdisServer.QueryStore

  @type parse_result :: {:ok, Key.t(), params_map :: map()} | {:error, reason :: term()}

  @doc """
  Parses a PostgREST path requested with the upstream `credential` into a
  cache key and the decoded query params.

  The key hashes a SHA-256 fingerprint of `credential` alongside the params, so
  the same path under two credentials yields two keys with the same ident.

  Also records the raw query string and `credential` of the resulting key in
  the `RestdisServer.QueryStore` (keyed by `tenant_id` and the key's wire
  representation) so that origin fetches issued later for this key -
  including cache-miss, rewarm, and fallback fetches - forward the original
  query string with the original credential to PostgREST.
  """
  @spec parse(String.t(), String.t(), String.t()) :: parse_result()
  def parse(tenant_id, path, credential)
      when is_binary(tenant_id) and is_binary(path) and is_binary(credential) do
    uri = URI.parse(path)

    with {:ok, scope, ident, segments} <- split_path(uri.path) do
      pairs = decode_pairs(uri.query)
      key = Key.build(scope, ident, segments, [credential_pair(credential) | pairs])
      QueryStore.put(tenant_id, Key.encode(key), uri.query || "", credential)
      {:ok, key, Map.new(pairs)}
    end
  end

  defp credential_pair(credential),
    do: {"__credential", Base.encode16(:crypto.hash(:sha256, credential))}

  defp split_path(nil), do: {:error, :missing_path}

  defp split_path(path) do
    case String.split(path, "/", trim: true) do
      ["rpc", ident | segments] -> {:ok, :rpc, ident, segments}
      [ident | segments] -> {:ok, :table, ident, segments}
      [] -> {:error, :empty_path}
    end
  end

  defp decode_pairs(nil), do: []

  defp decode_pairs(query), do: query |> URI.query_decoder() |> Enum.to_list()
end
