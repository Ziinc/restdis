defmodule RestdisServer.TestUtils do
  @moduledoc false

  @doc """
  Builds the handler state a command's `run/2` expects, for `tenant_id`.
  """
  @spec state(String.t()) :: map()
  def state(tenant_id), do: %{authenticated?: true, tenant_id: tenant_id, buffer: <<>>}

  @doc """
  Starts the rewarm scheduler of `tenant_id` and allows it (and its refetch
  tasks) to hit the calling test's `Req.Test` stub, so a test can observe or
  refute every origin request the scheduler makes.
  """
  @spec allow_rewarm_origin_requests(String.t()) :: pid()
  def allow_rewarm_origin_requests(tenant_id) do
    pid =
      case Registry.lookup(RestdisServer.Rewarm.Registry, tenant_id) do
        [{pid, _}] ->
          pid

        [] ->
          {:ok, pid} =
            DynamicSupervisor.start_child(
              RestdisServer.Rewarm.DynamicSupervisor,
              {RestdisServer.Rewarm.Scheduler, tenant_id: tenant_id}
            )

          pid
      end

    Req.Test.allow(RestdisServer.Finch, self(), pid)
    pid
  end

  @doc """
  Stubs the origin so every request it receives is sent to the calling test
  process as `{:origin_request, request_path}`.
  """
  @spec stub_origin_to_report_requests() :: :ok
  def stub_origin_to_report_requests do
    test_pid = self()

    Req.Test.stub(RestdisServer.Finch, fn conn ->
      send(test_pid, {:origin_request, conn.request_path})
      Req.Test.json(conn, [])
    end)
  end
end
