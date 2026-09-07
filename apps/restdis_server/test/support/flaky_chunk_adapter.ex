defmodule RestdisServer.Test.FlakyChunkAdapter do
  @moduledoc """
  A `Plug.Conn.Adapter` that wraps `Plug.Adapters.Test.Conn` but makes
  `chunk/2` fail after a configured number of successful writes, simulating a
  client that disconnects mid-stream.

  `Plug.Test`'s harness has no way to make a chunked write fail, so SSE's
  `{:error, conn}` branches (client gone mid-stream) are otherwise untestable.
  This adapter swaps in for the real one on an already-built `Plug.Conn`,
  after which `Plug.Conn.chunk/2` calls land here instead.

  Every callback besides `chunk/2` is a thin pass-through to the wrapped
  adapter; only `chunk/2` has interesting behaviour.
  """

  @behaviour Plug.Conn.Adapter

  @doc """
  Replaces `conn`'s adapter so its next `allowed` chunk writes succeed (via
  the real test adapter) and every write after that returns
  `{:error, :closed}`.
  """
  @spec install(Plug.Conn.t(), non_neg_integer()) :: Plug.Conn.t()
  def install(%Plug.Conn{adapter: {real_adapter, payload}} = conn, allowed) do
    %{conn | adapter: {__MODULE__, {real_adapter, payload, allowed}}}
  end

  @impl Plug.Conn.Adapter
  def chunk({_real_adapter, _payload, 0}, _body), do: {:error, :closed}

  def chunk({real_adapter, payload, allowed}, body) do
    case real_adapter.chunk(payload, body) do
      {:ok, body, new_payload} -> {:ok, body, {real_adapter, new_payload, allowed - 1}}
      {:error, _} = error -> error
    end
  end

  @impl Plug.Conn.Adapter
  def send_resp(payload, status, headers, body),
    do: rewrap(payload, :send_resp, [status, headers, body])

  @impl Plug.Conn.Adapter
  def send_file(payload, status, headers, path, offset, length),
    do: rewrap(payload, :send_file, [status, headers, path, offset, length])

  @impl Plug.Conn.Adapter
  def send_chunked(payload, status, headers),
    do: rewrap(payload, :send_chunked, [status, headers])

  @impl Plug.Conn.Adapter
  def read_req_body(payload, opts), do: rewrap(payload, :read_req_body, [opts])

  @impl Plug.Conn.Adapter
  def push({real_adapter, payload, _allowed}, path, headers),
    do: real_adapter.push(payload, path, headers)

  @impl Plug.Conn.Adapter
  def inform({real_adapter, payload, _allowed}, status, headers),
    do: real_adapter.inform(payload, status, headers)

  @impl Plug.Conn.Adapter
  def upgrade(payload, protocol, opts),
    do: rewrap(payload, :upgrade, [protocol, opts], one_tuple: true)

  @impl Plug.Conn.Adapter
  def get_peer_data({real_adapter, payload, _allowed}), do: real_adapter.get_peer_data(payload)

  @impl Plug.Conn.Adapter
  def get_sock_data({real_adapter, payload, _allowed}), do: real_adapter.get_sock_data(payload)

  @impl Plug.Conn.Adapter
  def get_ssl_data({real_adapter, payload, _allowed}), do: real_adapter.get_ssl_data(payload)

  @impl Plug.Conn.Adapter
  def get_http_protocol({real_adapter, payload, _allowed}),
    do: real_adapter.get_http_protocol(payload)

  # Calls `real_adapter.fun(real_payload, args...)` and re-wraps whatever new
  # payload comes back so subsequent calls still flow through this module.
  defp rewrap({real_adapter, payload, allowed}, fun, args, opts \\ []) do
    case apply(real_adapter, fun, [payload | args]) do
      {:error, _} = error ->
        error

      {:ok, new_payload} when opts != [] ->
        {:ok, {real_adapter, new_payload, allowed}}

      {tag, body, new_payload} ->
        {tag, body, {real_adapter, new_payload, allowed}}
    end
  end
end
