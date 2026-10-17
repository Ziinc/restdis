defmodule RestdisServer.StubFetcher do
  @moduledoc false

  @behaviour RestdisServer.PostgREST.Fetcher

  @impl RestdisServer.PostgREST.Fetcher
  def fetch(tenant_id, _key, _config) do
    case Application.get_env(:restdis_server, :stub_fetcher_agent) do
      nil -> :ok
      agent -> Agent.update(agent, &Map.update(&1, tenant_id, 1, fn n -> n + 1 end))
    end

    case Application.get_env(:restdis_server, :stub_fetcher_error) do
      nil ->
        body = Application.get_env(:restdis_server, :stub_fetcher_body, [%{"stub" => true}])
        {:ok, body}

      reason ->
        {:error, reason}
    end
  end
end
