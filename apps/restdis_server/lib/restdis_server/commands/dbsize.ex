defmodule RestdisServer.Commands.Dbsize do
  @moduledoc """
  Handles the RESP `DBSIZE` command.
  """

  alias RestdisServer.RESP.Encoder

  @doc """
  Replies with the number of keys held in the tenant's disk cache.
  """
  @spec run(map(), [binary()]) :: {iodata(), map()}
  def run(state, []) do
    {Encoder.integer(Restdis.Cache.size(state.tenant_id)), state}
  end

  def run(state, _),
    do: {Encoder.error("ERR wrong number of arguments for 'dbsize' command"), state}
end
