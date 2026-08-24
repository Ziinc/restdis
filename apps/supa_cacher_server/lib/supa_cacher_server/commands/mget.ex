defmodule SupaCacherServer.Commands.Mget do
  @moduledoc """
  Handles the RESP `MGET` command.
  """

  alias SupaCacherCache.Key
  alias SupaCacherServer.RESP.Encoder

  @spec run(map(), [binary()]) :: {iodata(), map()}
  def run(state, [_ | _] = wire_keys) do
    values = Enum.map(wire_keys, &fetch_encoded(state.tenant_id, &1))

    {Encoder.array(values), state}
  end

  def run(state, _),
    do: {Encoder.error("ERR wrong number of arguments for 'mget' command"), state}

  defp fetch_encoded(tenant_id, wire_key) do
    with {:ok, key} <- Key.decode(wire_key),
         {:ok, value} <- SupaCacherCache.get(tenant_id, key) do
      Jason.encode!(value)
    else
      _ -> nil
    end
  end
end
