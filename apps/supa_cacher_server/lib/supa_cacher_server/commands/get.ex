defmodule SupaCacherServer.Commands.Get do
  alias SupaCacherCache.Key
  alias SupaCacherServer.RESP.Encoder

  @spec run(map(), [binary()]) :: {iodata(), map()}
  def run(state, [wire_key]) do
    case Key.decode(wire_key) do
      {:ok, key} ->
        case SupaCacherCache.get(state.tenant_id, key) do
          {:ok, value} -> {Encoder.bulk_string(Jason.encode!(value)), state}
          :miss -> {Encoder.bulk_string(nil), state}
        end

      :error ->
        {Encoder.error("ERR only PGRST.* keys are supported"), state}
    end
  end

  def run(state, _), do: {Encoder.error("ERR wrong number of arguments for 'get' command"), state}
end
