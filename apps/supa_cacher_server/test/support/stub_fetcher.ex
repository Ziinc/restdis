defmodule SupaCacherServer.StubFetcher do
  @moduledoc false

  @behaviour SupaCacherServer.PostgREST.Fetcher

  @impl SupaCacherServer.PostgREST.Fetcher
  def fetch(_tenant_id, _key, _config) do
    case Application.get_env(:supa_cacher_server, :stub_fetcher_agent) do
      nil -> :ok
      agent -> Agent.update(agent, fn n -> n + 1 end)
    end

    body = Application.get_env(:supa_cacher_server, :stub_fetcher_body, [%{"stub" => true}])
    {:ok, body}
  end
end
