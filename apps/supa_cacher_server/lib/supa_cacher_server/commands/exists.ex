defmodule SupaCacherServer.Commands.Exists do
  @moduledoc """
  Handles the RESP `EXISTS` command.
  """

  alias SupaCacherCache.Key
  alias SupaCacherServer.RESP.Encoder

  @doc """
  Replies with the number of the given cache keys that are cached.
  """
  @spec run(map(), [binary()]) :: {iodata(), map()}
  def run(state, [_ | _] = wire_keys) do
    count = Enum.count(wire_keys, &cached?(state.tenant_id, &1))

    {Encoder.integer(count), state}
  end

  def run(state, _),
    do: {Encoder.error("ERR wrong number of arguments for 'exists' command"), state}

  defp cached?(tenant_id, wire_key) do
    with {:ok, key} <- Key.decode(wire_key),
         {:ok, _value} <- SupaCacherCache.get(tenant_id, key) do
      true
    else
      _ -> false
    end
  end
end
