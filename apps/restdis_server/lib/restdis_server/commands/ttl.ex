defmodule RestdisServer.Commands.Ttl do
  @moduledoc """
  Handles the RESP `TTL` command.
  """

  alias Restdis.Cache.Key
  alias RestdisServer.RESP.Encoder

  @doc """
  Replies with the seconds remaining before `wire_key` expires.
  """
  @spec run(map(), [binary()]) :: {iodata(), map()}
  def run(state, [wire_key]) do
    case Key.decode(wire_key) do
      {:ok, key} ->
        case Restdis.Cache.ttl(state.tenant_id, key) do
          :infinity -> {Encoder.integer(-1), state}
          :miss -> {Encoder.integer(-2), state}
          remaining_ms -> {Encoder.integer(div(remaining_ms, 1000)), state}
        end

      :error ->
        {Encoder.error("ERR only PGRST.* keys are supported"), state}
    end
  end

  def run(state, _), do: {Encoder.error("ERR wrong number of arguments for 'ttl' command"), state}
end
