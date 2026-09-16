defmodule RestdisServer.Commands.Dispatcher do
  @moduledoc """
  Routes a parsed RESP command to its handler, enforcing authentication first.
  """

  alias RestdisServer.Commands
  alias RestdisServer.RESP.Encoder

  @noauth_commands ~w(PING AUTH)

  @doc """
  Routes a parsed command to its handler, rejecting unauthenticated connections.
  """
  @spec dispatch(map(), [binary()]) :: {iodata(), map()}
  def dispatch(state, [cmd | args]) do
    upcmd = String.upcase(cmd)

    if not state.authenticated? and upcmd not in @noauth_commands do
      {Encoder.error("NOAUTH Authentication required"), state}
    else
      run(state, upcmd, args)
    end
  end

  def dispatch(state, []) do
    {Encoder.error("ERR empty command"), state}
  end

  defp run(state, "PING", args), do: Commands.Ping.run(state, args)
  defp run(state, "AUTH", args), do: Commands.Auth.run(state, args)
  defp run(state, "GET", args), do: Commands.Get.run(state, args)
  defp run(state, "SET", args), do: Commands.Set.run(state, args)
  defp run(state, "MGET", args), do: Commands.Mget.run(state, args)
  defp run(state, "DEL", args), do: Commands.Del.run(state, args)
  defp run(state, "TTL", args), do: Commands.Ttl.run(state, args)
  defp run(state, "EXISTS", args), do: Commands.Exists.run(state, args)
  defp run(state, "INCR", args), do: Commands.Incr.run(state, args)
  defp run(state, "DECR", args), do: Commands.Decr.run(state, args)
  defp run(state, "INCRBY", args), do: Commands.Incrby.run(state, args)
  defp run(state, "DECRBY", args), do: Commands.Decrby.run(state, args)
  defp run(state, "EXPIRE", args), do: Commands.Expire.run(state, args)
  defp run(state, "PEXPIRE", args), do: Commands.Pexpire.run(state, args)
  defp run(state, "PERSIST", args), do: Commands.Persist.run(state, args)
  defp run(state, "SETNX", args), do: Commands.Setnx.run(state, args)
  defp run(state, "GETSET", args), do: Commands.Getset.run(state, args)
  defp run(state, "GETDEL", args), do: Commands.Getdel.run(state, args)
  defp run(state, "APPEND", args), do: Commands.Append.run(state, args)
  defp run(state, "STRLEN", args), do: Commands.Strlen.run(state, args)
  defp run(state, "RENAME", args), do: Commands.Rename.run(state, args)
  defp run(state, "RENAMENX", args), do: Commands.Renamenx.run(state, args)
  defp run(state, "DBSIZE", args), do: Commands.Dbsize.run(state, args)
  defp run(state, "COPY", args), do: Commands.Copy.run(state, args)
  defp run(state, "PGRST.QUERY", args), do: Commands.PgrstQuery.run(state, args)
  defp run(state, "PGRST.POLICY", args), do: Commands.PgrstPolicy.run(state, args)

  defp run(state, cmd, _args) do
    {Encoder.error("ERR unknown command '#{cmd}'"), state}
  end
end
