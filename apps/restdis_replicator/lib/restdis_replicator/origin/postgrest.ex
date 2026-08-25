defmodule RestdisReplicator.Origin.PostgREST do
  @moduledoc """
  Origin implementation reading replicated rows from PostgREST with Req.

  Pagination uses the PostgREST `Range` header. The tenant configuration is
  resolved through the `:tenant_config_lookup` MFA so this context does not
  reach into the server context internals.
  """

  @behaviour RestdisReplicator.Origin

  alias RestdisReplicator.Dataset

  @impl RestdisReplicator.Origin
  def list_page(%Dataset{} = dataset, offset, limit) do
    with {:ok, config} <- tenant_config(dataset.tenant_id) do
      headers = [{"range-unit", "items"}, {"range", "#{offset}-#{offset + limit - 1}"}]
      request(dataset, config, query(dataset, %{}), headers)
    end
  end

  @impl RestdisReplicator.Origin
  def fetch_row(%Dataset{} = dataset, pk) do
    with {:ok, config} <- tenant_config(dataset.tenant_id),
         {:ok, rows} <-
           request(dataset, config, query(dataset, %{dataset.pk_column => "eq.#{pk}"}), []) do
      case rows do
        [row | _] -> {:ok, row}
        [] -> :not_found
      end
    end
  end

  defp request(dataset, config, params, headers) do
    base_url = config[:replica_url] || config.pgrst_base_url
    extra = Application.get_env(:restdis_replicator, :req_options, [])

    req =
      Req.new(
        [
          base_url: base_url,
          headers: [{"apikey", config.pgrst_api_key}] ++ headers,
          retry: false
        ] ++ extra
      )

    case Req.get(req, url: "/#{URI.encode(dataset.table)}", params: params) do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_list(body) ->
        {:ok, body}

      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, List.wrap(body)}

      {:ok, %{status: status}} ->
        {:error, {:status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp query(%Dataset{filter: nil}, params), do: params

  defp query(%Dataset{filter: filter}, params) do
    filter |> URI.decode_query() |> Map.merge(params)
  end

  defp tenant_config(tenant_id) do
    case Application.get_env(:restdis_replicator, :tenant_config_lookup) do
      {mod, fun, args} -> apply(mod, fun, [tenant_id | args])
      nil -> {:error, :no_tenant_config_lookup}
    end
  end
end
