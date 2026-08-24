defmodule SupaCacherServer.Commands.Del do
  @moduledoc """
  Handles the RESP `DEL` command.
  """

  alias SupaCacherCache.Key
  alias SupaCacherServer.RESP.Encoder

  @spec run(map(), [binary()]) :: {iodata(), map()}
  def run(state, [_ | _] = wire_keys) do
    deleted =
      Enum.reduce(wire_keys, 0, fn wire_key, acc ->
        case Key.decode(wire_key) do
          {:ok, key} ->
            SupaCacherCache.delete(state.tenant_id, key)
            SupaCacherServer.PolicyStore.delete(state.tenant_id, wire_key)
            acc + 1

          :error ->
            acc
        end
      end)

    {Encoder.integer(deleted), state}
  end

  def run(state, _), do: {Encoder.error("ERR wrong number of arguments for 'del' command"), state}
end
