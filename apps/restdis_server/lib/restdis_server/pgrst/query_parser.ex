defmodule RestdisServer.PGRST.QueryParser do
  @moduledoc """
  Parses a PostgREST request path into a cache key and its query params.
  """

  alias Restdis.Cache.Key

  @type parse_result :: {:ok, Key.t(), params_map :: map()} | {:error, reason :: term()}

  @doc """
  Parses a PostgREST path into a cache key and the decoded query params.
  """
  @spec parse(String.t()) :: parse_result()
  def parse(path) when is_binary(path) do
    uri = URI.parse(path)

    with {:ok, ident} <- extract_ident(uri.path) do
      scope = infer_scope(uri.path)
      params = decode_params(uri.query)
      {:ok, Key.build(scope, ident, params), params}
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
