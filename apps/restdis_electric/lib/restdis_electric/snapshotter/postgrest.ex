defmodule RestdisElectric.Snapshotter.PostgREST do
  @moduledoc """
  Snapshot reader that pages through PostgREST with `limit`/`offset`,
  ordered by the table's primary key so pages never overlap or skip rows.

  `tenant_config` may carry a `:req_options` keyword list, merged into the
  options passed to `Req.new/1` (a request option given here overrides the
  default of the same name). This exists purely as a testability seam — it
  lets tests point requests at a `Req.Test` stub or a local plug instead of
  a real PostgREST origin, without this module needing any test-only
  branch.
  """

  @behaviour RestdisElectric.Snapshotter

  alias RestdisElectric.Definition
  alias RestdisElectric.Snapshotter

  @impl RestdisElectric.Snapshotter
  def stream(tenant_config, %Definition{} = definition, page_fun) do
    case RestdisElectric.TableInfo.fetch(definition.schema, definition.table) do
      {:ok, info} ->
        order = Enum.join(info.primary_key, ",")
        req = %{tenant_config: tenant_config, definition: definition, order: order}
        page(req, 0, page_fun)

      :error ->
        {:error, {:unknown_table, Definition.qualified(definition)}}
    end
  end

  defp page(req, offset, page_fun) do
    case fetch_page(req, offset) do
      {:ok, []} ->
        :ok

      {:ok, rows} ->
        page_fun.(rows)

        if length(rows) < Snapshotter.page_size() do
          :ok
        else
          page(req, offset + Snapshotter.page_size(), page_fun)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_page(
         %{tenant_config: tenant_config, definition: definition, order: order},
         offset
       ) do
    base_url = tenant_config[:replica_url] || tenant_config.pgrst_base_url
    path = "/#{URI.encode(definition.table)}"

    query =
      [order: order, limit: Snapshotter.page_size(), offset: offset]
      |> maybe_select(definition.columns)

    http_req =
      Req.new(
        [
          base_url: base_url,
          headers: [{"apikey", tenant_config.pgrst_api_key}],
          retry: false
        ]
        |> Keyword.merge(tenant_config[:req_options] || [])
      )

    case Req.get(http_req, url: path, params: query) do
      {:ok, %{status: 200, body: body}} when is_list(body) -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_select(query, nil), do: query
  defp maybe_select(query, columns), do: Keyword.put(query, :select, Enum.join(columns, ","))
end
