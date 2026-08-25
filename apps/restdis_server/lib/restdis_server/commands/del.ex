defmodule RestdisServer.Commands.Del do
  @moduledoc """
  Handles the RESP `DEL` command.
  """

  alias Restdis.Cache.Key
  alias RestdisServer.RESP.Encoder

  @doc """
  Deletes the given cache keys and replies with the number removed.
  """
  @spec run(map(), [binary()]) :: {iodata(), map()}
  def run(state, [_ | _] = wire_keys) do
    deleted =
      Enum.reduce(wire_keys, 0, fn wire_key, acc ->
        case Key.decode(wire_key) do
          {:ok, key} ->
            Restdis.Cache.delete(state.tenant_id, key)
            RestdisServer.PolicyStore.delete(state.tenant_id, wire_key)
            acc + 1

          :error ->
            acc
        end
      end)

    {Encoder.integer(deleted), state}
  end

  def run(state, _), do: {Encoder.error("ERR wrong number of arguments for 'del' command"), state}
end
