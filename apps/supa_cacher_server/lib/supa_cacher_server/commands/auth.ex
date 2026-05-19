defmodule SupaCacherServer.Commands.Auth do
  alias SupaCacherServer.RESP.Encoder
  alias SupaCacherServer.TenantConfig

  @spec run(map(), [binary()]) :: {iodata(), map()}
  def run(state, [api_key]) do
    case TenantConfig.lookup_by_api_key(api_key) do
      {:ok, config} ->
        new_state = %{state | authenticated?: true, tenant_id: config.tenant_id}
        {Encoder.simple_string("OK"), new_state}

      {:error, :not_found} ->
        {Encoder.error("WRONGPASS invalid API key"), state}
    end
  end

  def run(state, _), do: {Encoder.error("ERR wrong number of arguments for 'auth' command"), state}
end
