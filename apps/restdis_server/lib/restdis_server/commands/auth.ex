defmodule RestdisServer.Commands.Auth do
  @moduledoc """
  Handles the RESP `AUTH` command.
  """

  alias RestdisServer.RESP.Encoder
  alias RestdisServer.TenantConfig

  @doc """
  Authenticates the connection with an API key and binds it to a tenant.
  """
  @spec run(map(), [binary()]) :: {iodata(), map()}
  def run(state, [api_key]) do
    case authenticate(state, api_key) do
      {:ok, new_state} -> {Encoder.simple_string("OK"), new_state}
      {:error, error} -> {error, state}
    end
  end

  def run(state, _),
    do: {Encoder.error("ERR wrong number of arguments for 'auth' command"), state}

  @doc """
  Binds the connection to the tenant owning `api_key`, or returns the
  `WRONGPASS` error reply.
  """
  @spec authenticate(map(), binary()) :: {:ok, map()} | {:error, iodata()}
  def authenticate(state, api_key) do
    case TenantConfig.lookup_by_api_key(api_key) do
      {:ok, config} -> {:ok, %{state | authenticated?: true, tenant_id: config.tenant_id}}
      {:error, :not_found} -> {:error, Encoder.error("WRONGPASS invalid API key")}
    end
  end
end
