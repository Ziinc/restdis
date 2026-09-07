defmodule RestdisServer.Commands.Getdel do
  @moduledoc """
  Handles the RESP `GETDEL` command.
  """

  alias Restdis.Cache.Router
  alias RestdisServer.Commands.Support
  alias RestdisServer.PolicyStore
  alias RestdisServer.RESP.Encoder

  @doc """
  Replies with the value stored under `wire_key`, deleting it in the same
  step.
  """
  @spec run(map(), [binary()]) :: {iodata(), map()}
  def run(state, [wire_key]) do
    case Support.decode_raw_key(wire_key) do
      {:ok, key} -> fetch_and_delete(state, key, wire_key)
      {:error, reply} -> {reply, state}
    end
  end

  def run(state, _),
    do: {Encoder.error("ERR wrong number of arguments for 'getdel' command"), state}

  defp fetch_and_delete(state, key, wire_key) do
    case Router.get(state.tenant_id, key) do
      {:ok, value} ->
        Restdis.Cache.delete(state.tenant_id, key)
        PolicyStore.delete(state.tenant_id, wire_key)
        {Encoder.bulk_string(value), state}

      :miss ->
        {Encoder.bulk_string(nil), state}

      {:error, :unreachable} ->
        {Encoder.error("ERR cache node unreachable"), state}
    end
  end
end
