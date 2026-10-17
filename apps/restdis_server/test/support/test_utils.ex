defmodule RestdisServer.TestUtils do
  @moduledoc false

  @doc """
  Builds the handler state a command's `run/2` expects, for `tenant_id`.
  """
  @spec state(String.t()) :: map()
  def state(tenant_id), do: %{authenticated?: true, tenant_id: tenant_id, buffer: <<>>}

  @doc """
  Starts a RESP listener on an ephemeral loopback port under the test supervisor and returns the port.
  """
  @spec start_resp_listener() :: :inet.port_number()
  def start_resp_listener do
    pid =
      ExUnit.Callbacks.start_supervised!(
        {ThousandIsland,
         port: 0, handler_module: RestdisServer.RESP.Handler, transport_options: [ip: :loopback]}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    port
  end

  @doc """
  Opens a passive binary TCP connection to the RESP listener on `port`.
  """
  @spec connect_resp(:inet.port_number()) :: :gen_tcp.socket()
  def connect_resp(port) do
    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw], 1_000)

    socket
  end

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
