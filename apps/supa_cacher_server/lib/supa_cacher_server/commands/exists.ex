defmodule SupaCacherServer.Commands.Exists do
  alias SupaCacherCache.Key
  alias SupaCacherServer.RESP.Encoder

  @spec run(map(), [binary()]) :: {iodata(), map()}
  def run(state, [_ | _] = wire_keys) do
    count =
      Enum.reduce(wire_keys, 0, fn wire_key, acc ->
        case Key.decode(wire_key) do
          {:ok, key} ->
            case SupaCacherCache.get(state.tenant_id, key) do
              {:ok, _} -> acc + 1
              :miss -> acc
            end

          :error ->
            acc
        end
      end)

    {Encoder.integer(count), state}
  end

  def run(state, _), do: {Encoder.error("ERR wrong number of arguments for 'exists' command"), state}
end
