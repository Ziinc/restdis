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
end
