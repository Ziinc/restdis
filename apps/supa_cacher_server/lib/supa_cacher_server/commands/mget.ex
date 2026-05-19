defmodule SupaCacherServer.Commands.Mget do
  alias SupaCacherCache.Key
  alias SupaCacherServer.RESP.Encoder

  @spec run(map(), [binary()]) :: {iodata(), map()}
  def run(state, [_ | _] = wire_keys) do
    values =
      Enum.map(wire_keys, fn wire_key ->
        case Key.decode(wire_key) do
          {:ok, key} ->
            case SupaCacherCache.get(state.tenant_id, key) do
              {:ok, value} -> Jason.encode!(value)
              :miss -> nil
            end

          :error ->
            nil
        end
      end)

    {Encoder.array(values), state}
  end

  def run(state, _), do: {Encoder.error("ERR wrong number of arguments for 'mget' command"), state}
end
